'use strict';

const { SSMClient, GetParameterCommand } = require('@aws-sdk/client-ssm');
const { timingSafeEqual, createVerify, createPublicKey, verify: verifySignature } = require('node:crypto');
const { readFileSync } = require('node:fs');
const path = require('node:path');

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
    };
  } catch (err) {
    console.error('identity_jwt_config.json could not be read, failing closed:', err.message);
    return { routeKeys: [], signingPublicKeyPem: '', anonymousPathPrefixes: [], apiKeyPrefixes: [] };
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
const JWKS_URL = process.env.IDENTITY_JWKS_URL || (ISSUER ? `${ISSUER}/.well-known/jwks.json` : '');

const JWT_ROUTE_KEYS = new Set(CONFIG.routeKeys.map((s) => String(s).trim()).filter(Boolean));

const ANONYMOUS_PATH_PREFIXES = CONFIG.anonymousPathPrefixes
  .map((s) => String(s).trim())
  .filter(Boolean);

const API_KEY_PREFIXES = CONFIG.apiKeyPrefixes
  .map((s) => String(s).trim())
  .filter(Boolean);

/** Returns the request path from either payload 2.0 shape. */
function requestPath(event) {
  return String(
    event.rawPath || ((event.requestContext || {}).http || {}).path || '',
  );
}

/** True when the request path matches a prefix that is admitted without any credential. */
function isAnonymousPath(event) {
  if (ANONYMOUS_PATH_PREFIXES.length === 0) {
    return false;
  }
  const path = requestPath(event);
  if (!path) {
    return false;
  }
  return ANONYMOUS_PATH_PREFIXES.some((prefix) => path === prefix || path.startsWith(prefix));
}

const JWKS_TTL_MS = Number(process.env.IDENTITY_JWKS_TTL_SECONDS || 300) * 1000;
const JWKS_TIMEOUT_MS = Number(process.env.IDENTITY_JWKS_TIMEOUT_MS || 2000);

const CLOCK_SKEW_SECONDS = Number(process.env.IDENTITY_CLOCK_SKEW_SECONDS || 60);

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

/** Constant-time string comparison. */
function equal(a, b) {
  const ab = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  return ab.length === bb.length && timingSafeEqual(ab, bb);
}

/** Case-insensitive header lookup against an already lowercased name. */
function header(event, name) {
  const headers = event.headers || {};
  for (const key of Object.keys(headers)) {
    if (key.toLowerCase() === name) {
      return headers[key];
    }
  }
  return undefined;
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

let jwksCache = { keys: null, fetchedAt: 0, inFlight: null };

/** Clears the per-environment JWKS cache. Exported for the tests. */
function resetJwksCache() {
  jwksCache = { keys: null, fetchedAt: 0, inFlight: null };
}

/**
 * Fetches the issuer's JWKS, presenting the origin verification header so the
 * fetch survives the gate that guards the issuer's own API.
 */
async function fetchJwks() {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), JWKS_TIMEOUT_MS);
  try {
    const headers = {};
    try {
      headers[HEADER_NAME] = await expected();
    } catch (err) {
      console.warn('origin verification value unavailable for the JWKS fetch:', err.message);
    }
    const response = await fetch(JWKS_URL, { signal: controller.signal, headers });
    if (!response.ok) {
      throw new Error(`JWKS fetch returned ${response.status}`);
    }
    const body = await response.json();
    const keys = Array.isArray(body && body.keys) ? body.keys : [];
    if (keys.length === 0) {
      throw new Error('JWKS has no keys');
    }
    return keys;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Returns the cached key set, refetching past the TTL or when `force` is set.
 * A failed refresh falls back to the cached keys rather than refusing every request.
 */
async function jwks(force) {
  const fresh = jwksCache.keys && Date.now() - jwksCache.fetchedAt < JWKS_TTL_MS;
  if (fresh && !force) {
    return jwksCache.keys;
  }
  if (jwksCache.inFlight) {
    return jwksCache.inFlight;
  }

  jwksCache.inFlight = fetchJwks()
    .then((keys) => {
      jwksCache = { keys, fetchedAt: Date.now(), inFlight: null };
      return keys;
    })
    .catch((err) => {
      jwksCache.inFlight = null;
      if (jwksCache.keys) {
        console.warn('JWKS refresh failed, using the cached key set:', err.message);
        return jwksCache.keys;
      }
      throw err;
    });

  return jwksCache.inFlight;
}

/** Decodes one base64url JWT segment into an object. */
function decodeSegment(segment) {
  return JSON.parse(Buffer.from(segment, 'base64url').toString('utf8'));
}

/**
 * Resolves the JWK for a kid, refetching once on a miss so a key rotation takes
 * effect within one request. Returns null when the kid stays unknown.
 */
async function keyFor(kid) {
  let keys = await jwks(false);
  let match = keys.find((k) => k.kid === kid);
  if (!match) {
    keys = await jwks(true);
    match = keys.find((k) => k.kid === kid);
  }
  if (!match) {
    return null;
  }
  if (match.kty !== 'RSA') {
    throw new Error(`JWKS key ${kid} is ${match.kty}, and only RSA is verifiable here`);
  }
  return createPublicKey({ key: match, format: 'jwk' });
}

/**
 * Verifies an RS256 access token against the issuer's JWKS and checks iss, aud,
 * exp and nbf. Returns the claims, or null with a logged reason.
 */
async function verifyAccessToken(token) {
  const parts = String(token).split('.');
  if (parts.length !== 3) {
    console.warn('access token rejected: not three segments');
    return null;
  }

  let head;
  let claims;
  try {
    head = decodeSegment(parts[0]);
    claims = decodeSegment(parts[1]);
  } catch (err) {
    console.warn('access token rejected: undecodable header or payload');
    return null;
  }

  if (head.alg !== 'RS256') {
    console.warn(`access token rejected: alg is ${head.alg}, only RS256 is accepted`);
    return null;
  }
  if (!head.kid) {
    console.warn('access token rejected: no kid in the header');
    return null;
  }

  let key;
  try {
    key = await keyFor(head.kid);
  } catch (err) {
    console.warn('access token rejected: JWKS unavailable:', err.message);
    return null;
  }
  if (!key) {
    console.warn('access token rejected: kid is not in the JWKS, including after a refresh');
    return null;
  }

  const signed = Buffer.from(`${parts[0]}.${parts[1]}`, 'utf8');
  const signature = Buffer.from(parts[2], 'base64url');
  if (!verifySignature('RSA-SHA256', signed, key, signature)) {
    console.warn('access token rejected: signature does not verify');
    return null;
  }

  if (claims.iss !== ISSUER) {
    console.warn('access token rejected: wrong issuer');
    return null;
  }

  const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!audiences.includes(AUDIENCE)) {
    console.warn('access token rejected: wrong audience');
    return null;
  }

  const now = Math.floor(Date.now() / 1000);
  if (typeof claims.exp !== 'number' || now >= claims.exp + CLOCK_SKEW_SECONDS) {
    console.warn('access token rejected: expired or no exp');
    return null;
  }
  if (typeof claims.nbf === 'number' && now < claims.nbf - CLOCK_SKEW_SECONDS) {
    console.warn('access token rejected: not yet valid');
    return null;
  }

  return claims;
}

/** Extracts the bearer token from the Authorization header, or null. */
function bearerToken(event) {
  const value = header(event, 'authorization');
  if (!value) {
    return null;
  }
  const match = /^Bearer[ ]+(.+)$/i.exec(String(value).trim());
  return match ? match[1].trim() : null;
}

/**
 * Shapes verified claims into the authorizer context, mirroring the native JWT
 * authorizer. Every value is a string, since API Gateway rejects nested objects.
 */
function claimsContext(claims) {
  const stringified = {};
  for (const [key, value] of Object.entries(claims)) {
    stringified[key] = typeof value === 'string' ? value : JSON.stringify(value);
  }
  return {
    'jwt.claims': JSON.stringify(stringified),
    'jwt.claims.sub': stringified.sub || '',
    'jwt.claims.iss': stringified.iss || '',
    'jwt.claims.exp': stringified.exp || '',
  };
}

/**
 * True when a bearer token is shaped like one of the packaged API key prefixes.
 * The token itself is never logged.
 */
function isApiKeyBearer(token) {
  if (API_KEY_PREFIXES.length === 0) {
    return false;
  }
  return API_KEY_PREFIXES.some((prefix) => String(token).startsWith(prefix));
}

/** True when this request's route key is one of the packaged token-enforced routes. */
function requiresIdentityJwt(event) {
  if (JWT_ROUTE_KEYS.size === 0 || !ISSUER || !AUDIENCE) {
    return false;
  }
  const routeKey = (event.routeKey || (event.requestContext || {}).routeKey || '').trim();
  return JWT_ROUTE_KEYS.has(routeKey);
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

  if (isAnonymousPath(event)) {
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

  if (!requiresIdentityJwt(event)) {
    return ALLOW;
  }

  const token = bearerToken(event);
  if (!token) {
    console.warn('denied: route requires an identity access token and no bearer token was presented');
    return DENY;
  }

  if (isApiKeyBearer(token)) {
    return ALLOW;
  }

  const claims = await verifyAccessToken(token);
  if (!claims) {
    return DENY;
  }

  return { isAuthorized: true, context: claimsContext(claims) };
};

exports.resetJwksCache = resetJwksCache;

/** Returns the anonymous path prefixes loaded from the package. For the tests. */
exports.anonymousPathPrefixes = () => [...ANONYMOUS_PATH_PREFIXES];

/** Returns the sorted route keys the handler is enforcing. For the tests. */
exports.enforcedRouteKeys = () => [...JWT_ROUTE_KEYS].sort();

/** Returns the bearer token prefixes passed through on JWT routes. For the tests. */
exports.apiKeyPrefixes = () => [...API_KEY_PREFIXES];
