'use strict';

// HTTP API REQUEST authorizer (payload 2.0). The authorizer has no identity sources, so API Gateway
// invokes it on every request to a route that uses it and never caches the answer; the SSM read
// below still happens once per cold start and is reused after that.
//
// It does two jobs, and the second one is optional.
//
// THE GATE. A request is admitted when any of these holds, checked in order:
//
//   1. it is a CORS preflight (OPTIONS), which carries no credentials and is answered by the
//      application's own CORS middleware;
//   2. it carries the origin verification header with the value in SSM, which is how CloudFront
//      and non-browser callers (pipelines, health checks) reach the API;
//   3. it carries the access gate's own CloudFront signed cookies, valid for this key pair, not
//      expired, and scoped to this gate's cookie domain. That is what lets a browser call
//      https://api.<cookie_domain> directly: the cookies are set on the parent domain, so they
//      ride along on same-site credentialed requests.
//
// THE IDENTITY ACCESS TOKEN, when identity_jwt_config.json lists this request's route key. The gate
// check above still has to pass first; this is an additional requirement, never a replacement. The
// request must then also carry `Authorization: Bearer <token>` holding an RS256 JWT that verifies
// against the issuer's JWKS and whose iss, aud, exp and nbf all check out. The claims are handed to
// the integration in the authorizer context.
//
// WHY THE ROUTE KEY IS THE SIGNAL. A payload 2.0 authorizer event does not name the authorizer that
// invoked the function: `routeArn` is a route ARN and there is no authorizer id anywhere in the
// event, so two authorizer resources over one Lambda would be indistinguishable from inside it.
// `requestContext.routeKey` is in the event, and it is exactly the string the http-api module keys
// its routes by, so both sides name the same route with the same string by construction. The list
// comes from that module's identity_jwt_route_keys output.
//
// WHY THERE IS NO JWT LIBRARY HERE. This function is zipped straight from its source directory by
// archive_file, with no npm install anywhere in a consumer's Terraform run, so a dependency would
// have to be vendored into the module and kept patched by hand. Everything needed is in node:crypto
// on Node 22: it imports a JWK directly and verifies RSA-SHA256, which is the only family the
// identity module's keys can be (RSA is what the HTTP API JWT authorizer supports, so the module
// refuses an EC key spec). The verification below is deliberately strict and allows exactly one
// algorithm: `alg` is read only to refuse anything that is not RS256, and never to choose a
// verifier, which is the "alg: none" and HMAC-confusion class of bug.
//
// Cookie values and token contents are never logged.

const { SSMClient, GetParameterCommand } = require('@aws-sdk/client-ssm');
const { timingSafeEqual, createVerify, createPublicKey, verify: verifySignature } = require('node:crypto');
const { readFileSync } = require('node:fs');
const path = require('node:path');

// WHY THE BIG VALUES ARE NOT IN THE ENVIRONMENT. A Lambda's environment is capped at 4096 bytes
// across every variable together, and the API measures it only at UpdateFunctionConfiguration:
// Terraform's plan is green and the apply fails with "environment variables exceeded the 4KB
// limit". The enforced route key list is the value that grows without bound (95 keys serialised to
// 3600 bytes in CarModPicker staging, which put the whole environment at 4545 bytes) and the
// signing public key PEM is another 451 bytes. The list cannot be trimmed, because a key missing
// from it is a route nobody enforces, and it cannot be prefix matched, because the anonymous guard
// routes sit under the same prefixes as enforced ones and prefix matching would enforce on them.
//
// So the Terraform module renders both into identity_jwt_config.json and writes that file into the
// deployment package, which has no such cap. It is read once here at import time, so it costs one
// synchronous read per execution environment and nothing per request. The file is always present:
// the module writes it with an empty route_keys list when nothing is enforced, so there is one code
// path rather than two.
//
// The file is part of the archive, so its bytes are part of source_code_hash and a changed route
// key list redeploys the function.
const CONFIG_PATH = path.join(__dirname, 'identity_jwt_config.json');

function loadConfig() {
  try {
    const parsed = JSON.parse(readFileSync(CONFIG_PATH, 'utf8'));
    return {
      routeKeys: Array.isArray(parsed.route_keys) ? parsed.route_keys : [],
      signingPublicKeyPem: typeof parsed.signing_public_key_pem === 'string' ? parsed.signing_public_key_pem : '',
    };
  } catch (err) {
    // A package without the file is a packaging bug, not a request the function should answer
    // permissively. Returning empty values makes the gate's cookie check fail closed (no public key
    // means no signed cookie verifies) rather than silently dropping token enforcement while still
    // admitting traffic.
    console.error('identity_jwt_config.json could not be read, failing closed:', err.message);
    return { routeKeys: [], signingPublicKeyPem: '' };
  }
}

const CONFIG = loadConfig();

const ssm = new SSMClient({});
const HEADER_NAME = (process.env.HEADER_NAME || 'x-origin-verify').toLowerCase();
const KEY_PAIR_ID = process.env.KEY_PAIR_ID || '';
const PUBLIC_KEY_PEM = CONFIG.signingPublicKeyPem;
const COOKIE_DOMAIN = process.env.COOKIE_DOMAIN || '';
const EXPECTED_RESOURCE = `https://*${COOKIE_DOMAIN}/*`;

// Identity JWT configuration. The issuer and audience are short scalars and stay in the
// environment; the route key list is in the package. All three have to be present for enforcement to
// be possible at all; an issuer with no routes listed is a gate that checks nothing extra, which is
// the default.
const ISSUER = process.env.IDENTITY_ISSUER || '';
const AUDIENCE = process.env.IDENTITY_AUDIENCE || '';
const JWKS_URL = process.env.IDENTITY_JWKS_URL || (ISSUER ? `${ISSUER}/.well-known/jwks.json` : '');

// The route keys that require a token, read from the package rather than the environment (see the
// top of this file). Matched exactly, never by prefix: a Set of the literal "<METHOD> <path>"
// strings the http-api module keys its routes by, compared against requestContext.routeKey. A key
// that is not in this Set is a route that is not enforced, which is how the anonymous guard routes
// stay anonymous while sharing a path prefix with enforced ones.
//
// The module sorts the list before rendering it, so the file's bytes, and therefore the function's
// source hash, do not move when a consumer reorders its input.
const JWT_ROUTE_KEYS = new Set(CONFIG.routeKeys.map((s) => String(s).trim()).filter(Boolean));

// How long a fetched JWKS is reused, and how long a fetch may take. Short, because the cost of a
// stale key set is requests failing after a rotation and the cost of a fetch is one HTTPS call per
// execution environment per interval.
const JWKS_TTL_MS = Number(process.env.IDENTITY_JWKS_TTL_SECONDS || 300) * 1000;
const JWKS_TIMEOUT_MS = Number(process.env.IDENTITY_JWKS_TIMEOUT_MS || 2000);

// Leeway on the time-based claims, for clock skew between the signer and this function.
const CLOCK_SKEW_SECONDS = Number(process.env.IDENTITY_CLOCK_SKEW_SECONDS || 60);

const ALLOW = { isAuthorized: true };
const DENY = { isAuthorized: false };

let expectedPromise;

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

function equal(a, b) {
  const ab = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  return ab.length === bb.length && timingSafeEqual(ab, bb);
}

function header(event, name) {
  const headers = event.headers || {};
  for (const key of Object.keys(headers)) {
    if (key.toLowerCase() === name) {
      return headers[key];
    }
  }
  return undefined;
}

// CloudFront's URL-safe base64: + becomes -, = becomes _, / becomes ~.
function fromCloudFrontBase64(value) {
  return Buffer.from(String(value).replace(/-/g, '+').replace(/_/g, '=').replace(/~/g, '/'), 'base64');
}

// Payload 2.0 exposes cookies as an array; the raw cookie header is read as well so the function
// behaves the same when it is handed a plain header map.
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

// The same policy the login Lambda signs: RSA-SHA1 over the compact policy JSON, checked against
// the public half of the CloudFront key pair. The PEM is public (CloudFront publishes it and it only
// verifies signatures), so it needs no SSM read; it rides in identity_jwt_config.json rather than an
// environment variable only because of the 4096 byte environment cap.
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

// ---------------------------------------------------------------------------
// The identity access token
// ---------------------------------------------------------------------------

// The JWKS cache. One entry per execution environment, holding the key set, when it was fetched and
// the in-flight promise so a burst of concurrent requests on a cold start makes one fetch rather
// than one each.
let jwksCache = { keys: null, fetchedAt: 0, inFlight: null };

// Exported for the tests, which need each case to start from a clean cache.
function resetJwksCache() {
  jwksCache = { keys: null, fetchedAt: 0, inFlight: null };
}

// The fetch itself. Overridable through globalThis.fetch, which is how the tests stub it without a
// network.
async function fetchJwks() {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), JWKS_TIMEOUT_MS);
  try {
    const response = await fetch(JWKS_URL, { signal: controller.signal });
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

// Returns the cached key set, refetching when it is older than the TTL. `force` skips the TTL and
// is what an unknown `kid` triggers: a key that was added since the last fetch is the expected
// reason for one, and waiting out the TTL would mean every token signed by the new key is refused
// until it expires.
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
      // A failed refresh falls back to whatever is cached rather than refusing every request: the
      // keys do not change often, and an issuer that is briefly unreachable should not take the API
      // down. A cold start with no cache has nothing to fall back to and rethrows.
      if (jwksCache.keys) {
        console.warn('JWKS refresh failed, using the cached key set:', err.message);
        return jwksCache.keys;
      }
      throw err;
    });

  return jwksCache.inFlight;
}

function decodeSegment(segment) {
  return JSON.parse(Buffer.from(segment, 'base64url').toString('utf8'));
}

// Finds the JWK for this token. An unknown kid refetches once, which is what makes a key rotation
// take effect within one request rather than within the TTL.
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

// Verifies the token and returns its claims, or null. Every rejection is logged with a reason and
// without the token.
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

  // The only algorithm this function will verify. Read to refuse, never to select: taking the
  // verifier from the token is how "alg: none" and RS256-to-HS256 confusion get in.
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

  // Signature first, claims second: everything below is only meaningful once the bytes are known to
  // be the issuer's.
  if (claims.iss !== ISSUER) {
    console.warn('access token rejected: wrong issuer');
    return null;
  }

  // aud is a string or an array of strings per RFC 7519.
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

function bearerToken(event) {
  const value = header(event, 'authorization');
  if (!value) {
    return null;
  }
  const match = /^Bearer[ ]+(.+)$/i.exec(String(value).trim());
  return match ? match[1].trim() : null;
}

// The authorizer context, shaped to mirror the native JWT authorizer as closely as a Lambda
// authorizer can.
//
// It cannot be identical, and the difference is worth stating rather than papering over. A native
// JWT authorizer puts claims at requestContext.authorizer.jwt.claims; a Lambda authorizer's context
// always lands under requestContext.authorizer.lambda, and API Gateway stringifies every value and
// rejects nested objects outright. So the closest faithful mirror is one string key literally named
// "jwt.claims" holding the claims as JSON, which the application reads in one line:
//
//     claims = ctx.get("jwt", {}).get("claims") or json.loads(ctx["lambda"]["jwt.claims"])
//
// Every value inside it is a string, exactly as the native authorizer delivers them, so `exp` is
// "1757200000" in both environments and code that parses it needs no environment-specific branch.
function claimsContext(claims) {
  const stringified = {};
  for (const [key, value] of Object.entries(claims)) {
    stringified[key] = typeof value === 'string' ? value : JSON.stringify(value);
  }
  return {
    'jwt.claims': JSON.stringify(stringified),
    // The three the application reads most often, lifted out so a caller that wants only the
    // subject does not have to parse the JSON blob.
    'jwt.claims.sub': stringified.sub || '',
    'jwt.claims.iss': stringified.iss || '',
    'jwt.claims.exp': stringified.exp || '',
  };
}

function requiresIdentityJwt(event) {
  if (JWT_ROUTE_KEYS.size === 0 || !ISSUER || !AUDIENCE) {
    return false;
  }
  const routeKey = (event.routeKey || (event.requestContext || {}).routeKey || '').trim();
  return JWT_ROUTE_KEYS.has(routeKey);
}

exports.handler = async (event) => {
  const method = (((event.requestContext || {}).http || {}).method || '').toUpperCase();

  // A CORS preflight is sent without credentials, so it can never carry the header, the cookies or
  // a token. Letting it through lets the application's own CORS middleware answer it, and it is
  // exempt from the token requirement for the same reason.
  if (method === 'OPTIONS') {
    return ALLOW;
  }

  // The gate first, unchanged. A request that cannot get past it is refused whether or not it
  // carries a token, so the token check never widens access.
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

  const claims = await verifyAccessToken(token);
  if (!claims) {
    return DENY;
  }

  return { isAuthorized: true, context: claimsContext(claims) };
};

// For the unit tests.
exports.resetJwksCache = resetJwksCache;

// Also for the unit tests: the route key set as it was loaded from the package, so a test can assert
// what the handler is actually enforcing rather than what it was handed.
exports.enforcedRouteKeys = () => [...JWT_ROUTE_KEYS].sort();
