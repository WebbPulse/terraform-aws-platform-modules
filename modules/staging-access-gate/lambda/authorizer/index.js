'use strict';

const { SSMClient, GetParameterCommand } = require('@aws-sdk/client-ssm');
const { timingSafeEqual, createVerify } = require('node:crypto');
const { readFileSync } = require('node:fs');
const path = require('node:path');

const {
  DEFAULT_JWKS_FETCH_TIMEOUT_MS,
  createIdentityVerifier,
  header,
} = require('./identity.js');

const CONFIG_PATH = path.join(__dirname, 'identity_jwt_config.json');

/**
 * Reads the packaged identity JWT configuration.
 * Returns empty values when the file is unreadable so the gate fails closed.
 */
function loadConfig() {
  try {
    const parsed = JSON.parse(readFileSync(CONFIG_PATH, 'utf8'));
    return {
      routeKeys: Array.isArray(parsed.route_keys) ? parsed.route_keys : [],
      signingPublicKeyPem: typeof parsed.signing_public_key_pem === 'string' ? parsed.signing_public_key_pem : '',
      anonymousPathPrefixes: Array.isArray(parsed.anonymous_path_prefixes) ? parsed.anonymous_path_prefixes : [],
      apiKeyPrefixes: Array.isArray(parsed.api_key_prefixes) ? parsed.api_key_prefixes : [],
      jwksFetchTimeoutMs: Number(parsed.jwks_fetch_timeout_ms) > 0 ? Number(parsed.jwks_fetch_timeout_ms) : DEFAULT_JWKS_FETCH_TIMEOUT_MS,
    };
  } catch (err) {
    console.error('identity_jwt_config.json could not be read, failing closed:', err.message);
    return {
      routeKeys: [],
      signingPublicKeyPem: '',
      anonymousPathPrefixes: [],
      apiKeyPrefixes: [],
      jwksFetchTimeoutMs: DEFAULT_JWKS_FETCH_TIMEOUT_MS,
    };
  }
}

const CONFIG = loadConfig();

const ssm = new SSMClient({});
const HEADER_NAME = (process.env.HEADER_NAME || 'x-origin-verify').toLowerCase();
const KEY_PAIR_ID = process.env.KEY_PAIR_ID || '';
const PUBLIC_KEY_PEM = CONFIG.signingPublicKeyPem;
const COOKIE_DOMAIN = process.env.COOKIE_DOMAIN || '';
const EXPECTED_RESOURCE = `https://*${COOKIE_DOMAIN}/*`;

const ISSUER = process.env.IDENTITY_ISSUER || '';
const AUDIENCE = process.env.IDENTITY_AUDIENCE || '';

const ALLOW = { isAuthorized: true };
const DENY = { isAuthorized: false };

let expectedPromise;

/** Resolves the origin verification value from SSM, reading it once per execution environment. */
function expected() {
  if (!expectedPromise) {
    expectedPromise = ssm
      .send(new GetParameterCommand({ Name: process.env.ORIGIN_VERIFY_PARAM, WithDecryption: true }))
      .then((r) => r.Parameter.Value)
      .catch((err) => {
        expectedPromise = undefined;
        throw err;
      });
  }
  return expectedPromise;
}

/**
 * The identity half of this authorizer, shared byte for byte with the http-api
 * module's Lambda authorizer. The JWKS fetch carries the origin verification
 * header, because in the gate topology the issuer is the same API this
 * authorizer guards, so a bare fetch would be refused by the gate itself.
 */
const identity = createIdentityVerifier({
  issuer: ISSUER,
  audience: AUDIENCE,
  jwksUrl: process.env.IDENTITY_JWKS_URL || undefined,
  jwksTtlSeconds: process.env.IDENTITY_JWKS_TTL_SECONDS,
  jwksFetchTimeoutMs: CONFIG.jwksFetchTimeoutMs,
  jwksRetryBudgetMs: process.env.IDENTITY_JWKS_RETRY_BUDGET_MS,
  clockSkewSeconds: process.env.IDENTITY_CLOCK_SKEW_SECONDS,
  routeKeys: CONFIG.routeKeys,
  apiKeyPrefixes: CONFIG.apiKeyPrefixes,
  anonymousPathPrefixes: CONFIG.anonymousPathPrefixes,
  fetchHeaders: async () => {
    try {
      return { [HEADER_NAME]: await expected() };
    } catch (err) {
      console.warn('origin verification value unavailable for the JWKS fetch:', err.message);
      return {};
    }
  },
});

/** Constant-time string comparison. */
function equal(a, b) {
  const ab = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  return ab.length === bb.length && timingSafeEqual(ab, bb);
}

/** Decodes CloudFront's URL-safe base64 alphabet, where -, _ and ~ stand for +, = and /. */
function fromCloudFrontBase64(value) {
  return Buffer.from(String(value).replace(/-/g, '+').replace(/_/g, '=').replace(/~/g, '/'), 'base64');
}

/** Collects cookies from the payload 2.0 array and from a raw cookie header. */
function parseCookies(event) {
  const out = {};
  const raw = [];
  if (Array.isArray(event.cookies)) {
    raw.push(...event.cookies);
  }
  const headerValue = header(event, 'cookie');
  if (headerValue) {
    raw.push(...String(headerValue).split(';'));
  }
  for (const pair of raw) {
    const i = pair.indexOf('=');
    if (i > 0) {
      const name = pair.slice(0, i).trim();
      if (!(name in out)) {
        out[name] = pair.slice(i + 1).trim();
      }
    }
  }
  return out;
}

/**
 * Verifies the gate's CloudFront signed cookies against this key pair.
 * The policy must be unexpired and scoped to this gate's cookie domain.
 */
function signedCookiesValid(event) {
  if (!KEY_PAIR_ID || !PUBLIC_KEY_PEM || !COOKIE_DOMAIN) {
    return false;
  }

  const cookies = parseCookies(event);
  const keyPairId = cookies['CloudFront-Key-Pair-Id'];
  const policyCookie = cookies['CloudFront-Policy'];
  const signatureCookie = cookies['CloudFront-Signature'];
  if (!keyPairId || !policyCookie || !signatureCookie) {
    return false;
  }
  if (!equal(keyPairId, KEY_PAIR_ID)) {
    return false;
  }

  let policyJson;
  let statement;
  try {
    policyJson = fromCloudFrontBase64(policyCookie).toString('utf8');
    const signature = fromCloudFrontBase64(signatureCookie);
    if (!createVerify('RSA-SHA1').update(policyJson, 'utf8').verify(PUBLIC_KEY_PEM, signature)) {
      return false;
    }
    statement = (JSON.parse(policyJson).Statement || [])[0];
  } catch (err) {
    console.warn('signed cookie rejected:', err.message);
    return false;
  }

  if (!statement || statement.Resource !== EXPECTED_RESOURCE) {
    return false;
  }
  const expires = ((statement.Condition || {}).DateLessThan || {})['AWS:EpochTime'];
  return typeof expires === 'number' && expires > Math.floor(Date.now() / 1000);
}

/**
 * HTTP API REQUEST authorizer (payload 2.0). Admits preflights and anonymous key
 * material paths, then requires the origin verification header or valid gate
 * cookies, and additionally an identity access token on enforced route keys.
 * A bearer matching a configured API key prefix is passed through with no claims
 * context, for the function to verify itself.
 */
exports.handler = async (event) => {
  const method = (((event.requestContext || {}).http || {}).method || '').toUpperCase();

  if (method === 'OPTIONS') {
    return ALLOW;
  }

  if (identity.isAnonymousPath(event)) {
    return ALLOW;
  }

  let gateOk = false;
  const presented = header(event, HEADER_NAME);
  if (presented !== undefined) {
    const want = await expected();
    if (equal(presented, want)) {
      gateOk = true;
    }
  }
  if (!gateOk) {
    gateOk = signedCookiesValid(event);
  }
  if (!gateOk) {
    return DENY;
  }

  if (!identity.requiresIdentityJwt(event)) {
    return ALLOW;
  }

  const token = identity.bearerToken(event);
  if (!token) {
    console.warn('denied: route requires an identity access token and no bearer token was presented');
    return DENY;
  }

  if (identity.isApiKeyBearer(token)) {
    return ALLOW;
  }

  const claims = await identity.verifyAccessToken(token);
  if (!claims) {
    return DENY;
  }

  return { isAuthorized: true, context: identity.claimsContext(claims) };
};

exports.resetJwksCache = identity.resetJwksCache;

/** Returns the anonymous path prefixes loaded from the package. For the tests. */
exports.anonymousPathPrefixes = identity.anonymousPathPrefixes;

/** Returns the sorted route keys the handler is enforcing. For the tests. */
exports.enforcedRouteKeys = identity.enforcedRouteKeys;

/** Returns the bearer token prefixes passed through on JWT routes. For the tests. */
exports.apiKeyPrefixes = identity.apiKeyPrefixes;
