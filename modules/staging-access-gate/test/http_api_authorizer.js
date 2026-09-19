/**
 * Unit tests for the http-api module's identity Lambda authorizer.
 *
 * It shares its verification with the gate authorizer through
 * shared/identity-authorizer/identity.js, so these assertions are about the two
 * behaving identically on a token: the same admission for a valid access token,
 * the same passthrough for an API key bearer, and the same claims context, with
 * none of the gate's cookie or origin secret admission carried over.
 */

const assert = require('node:assert');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const HANDLER = path.join(__dirname, '..', '..', 'http-api', 'lambda', 'authorizer', 'index.js');
const SHARED = path.join(__dirname, '..', '..', '..', 'shared', 'identity-authorizer', 'identity.js');
const ROOT = path.join(__dirname, '.build');

const ISSUER = 'https://api.example.com/api/auth';
const AUDIENCE = 'example-production-api';
const PROTECTED = 'GET /api/auth/me';
const UNCONFIGURED = 'GET /api/somewhere-else';

const signer = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const KID = 'key-one';

let counter = 0;

/** Renders identity_jwt_config.json exactly as the http-api locals do. */
function renderConfig({ routeKeys = [], apiKeyPrefixes = [], jwksFetchTimeoutMs = 4000 } = {}) {
  return JSON.stringify({
    route_keys: [...routeKeys].sort(),
    api_key_prefixes: apiKeyPrefixes,
    jwks_fetch_timeout_ms: jwksFetchTimeoutMs,
  });
}

/** Builds the deployment package the way the archive_file does and loads the handler. */
function loadAuthorizer(config) {
  counter += 1;
  const dir = path.join(ROOT, `http-api-authorizer-${counter}`);
  fs.mkdirSync(dir, { recursive: true });
  fs.copyFileSync(HANDLER, path.join(dir, 'index.js'));
  fs.copyFileSync(SHARED, path.join(dir, 'identity.js'));
  fs.writeFileSync(path.join(dir, 'identity_jwt_config.json'), renderConfig(config));
  const entry = path.join(dir, 'index.js');
  delete require.cache[entry];
  delete require.cache[path.join(dir, 'identity.js')];
  return require(entry);
}

/** Exports a public key as a JWKS entry with the given kid. */
function jwk(publicKey, kid) {
  return { ...publicKey.export({ format: 'jwk' }), kid, alg: 'RS256', use: 'sig' };
}

/** Signs claims into a compact JWT. */
function sign(claims, { key = signer.privateKey, kid = KID, alg = 'RS256' } = {}) {
  const header = Buffer.from(JSON.stringify({ alg, kid, typ: 'JWT' })).toString('base64url');
  const payload = Buffer.from(JSON.stringify(claims)).toString('base64url');
  const signature = crypto
    .sign('RSA-SHA256', Buffer.from(`${header}.${payload}`, 'utf8'), key)
    .toString('base64url');
  return `${header}.${payload}.${signature}`;
}

const now = () => Math.floor(Date.now() / 1000);

/** A valid claim set for this issuer and audience. */
function claims(overrides = {}) {
  return {
    sub: 'user-123',
    iss: ISSUER,
    aud: AUDIENCE,
    exp: now() + 900,
    iat: now(),
    email: 'me@example.com',
    roles: ['admin', 'user'],
    ...overrides,
  };
}

/** Builds a payload 2.0 authorizer event. */
function req({ routeKey = PROTECTED, method = 'GET', token, headers = {} } = {}) {
  const all = { ...headers };
  if (token) {
    all.authorization = `Bearer ${token}`;
  }
  return {
    routeKey,
    headers: all,
    requestContext: { http: { method }, routeKey },
  };
}

/** Runs the http-api authorizer assertions. */
module.exports = async function run() {
  process.env.IDENTITY_ISSUER = ISSUER;
  process.env.IDENTITY_AUDIENCE = AUDIENCE;
  process.env.IDENTITY_JWKS_TTL_SECONDS = '300';
  delete process.env.IDENTITY_JWKS_URL;

  const originalFetch = global.fetch;
  let fetches = 0;
  let lastHeaders;
  global.fetch = async (url, init) => {
    fetches += 1;
    lastHeaders = (init && init.headers) || {};
    return { ok: true, status: 200, json: async () => ({ keys: [jwk(signer.publicKey, KID)] }) };
  };

  const auth = loadAuthorizer({ routeKeys: [PROTECTED], apiKeyPrefixes: ['wpk_'] });

  assert.deepStrictEqual(auth.enforcedRouteKeys(), [PROTECTED], 'the packaged route keys are enforced');
  assert.deepStrictEqual(auth.apiKeyPrefixes(), ['wpk_'], 'the packaged prefixes are loaded');

  assert.deepStrictEqual(
    await auth.handler(req({ method: 'OPTIONS' })),
    { isAuthorized: true },
    'a CORS preflight carries no token and must be admitted',
  );

  const good = await auth.handler(req({ token: sign(claims()) }));
  assert.strictEqual(good.isAuthorized, true, 'a valid access token is admitted');
  assert.strictEqual(good.context['jwt.claims.sub'], 'user-123', 'the sub reaches the integration');
  assert.strictEqual(good.context['jwt.claims.iss'], ISSUER, 'the issuer reaches the integration');
  assert.strictEqual(
    JSON.parse(good.context['jwt.claims']).roles,
    JSON.stringify(['admin', 'user']),
    'a non-string claim is stringified the way the native authorizer does',
  );
  assert.strictEqual(
    typeof good.context['jwt.claims.exp'],
    'string',
    'exp arrives as a string, matching the native authorizer',
  );

  assert.deepStrictEqual(
    await auth.handler(req({ token: 'wpk_live_abc123' })),
    { isAuthorized: true },
    'an API key bearer is passed through, which is the whole point of lambda mode',
  );
  assert.deepStrictEqual(
    await auth.handler(req({ token: 'wpk_' })),
    { isAuthorized: true },
    'the bare prefix is still a prefix match',
  );

  const beforeUnknown = fetches;
  assert.deepStrictEqual(
    await auth.handler(req({ token: 'nope_abc123' })),
    { isAuthorized: false },
    'a bearer matching no prefix and no JWT shape is denied',
  );
  assert.deepStrictEqual(
    await auth.handler(req({})),
    { isAuthorized: false },
    'no bearer at all is denied: there is no gate credential to fall back on here',
  );
  assert.strictEqual(fetches, beforeUnknown, 'a malformed bearer never reaches the JWKS');

  assert.deepStrictEqual(
    await auth.handler(req({ routeKey: UNCONFIGURED, token: sign(claims()) })),
    { isAuthorized: false },
    'a route the package does not enforce is denied, so a stray attachment fails closed',
  );

  assert.deepStrictEqual(
    await auth.handler(req({ token: sign(claims({ aud: 'example-staging-api' })) })),
    { isAuthorized: false },
    'a token for another audience is denied, which is what stops a staging token opening production',
  );
  assert.deepStrictEqual(
    await auth.handler(req({ token: sign(claims({ iss: 'https://evil.example.com' })) })),
    { isAuthorized: false },
    'a token from another issuer is denied',
  );
  assert.deepStrictEqual(
    await auth.handler(req({ token: sign(claims({ exp: now() - 3600 })) })),
    { isAuthorized: false },
    'an expired token is denied',
  );
  assert.deepStrictEqual(
    await auth.handler(req({ token: sign(claims(), { alg: 'none' }) })),
    { isAuthorized: false },
    'alg none is denied',
  );

  const foreign = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  assert.deepStrictEqual(
    await auth.handler(req({ token: sign(claims(), { key: foreign.privateKey }) })),
    { isAuthorized: false },
    'a token signed by a foreign key is denied',
  );

  assert.deepStrictEqual(
    lastHeaders,
    {},
    'the http-api authorizer fetches the JWKS bare: there is no gate in front of the issuer here',
  );

  const cached = fetches;
  await auth.handler(req({ token: sign(claims({ sub: 'user-456' })) }));
  assert.strictEqual(fetches, cached, 'the key set is cached across invocations');

  const noPrefixes = loadAuthorizer({ routeKeys: [PROTECTED] });
  assert.deepStrictEqual(
    await noPrefixes.handler(req({ token: 'wpk_live_abc123' })),
    { isAuthorized: false },
    'with no prefixes configured an API key bearer is denied, which is native mode behaviour',
  );

  const broken = (() => {
    counter += 1;
    const dir = path.join(ROOT, `http-api-authorizer-${counter}`);
    fs.mkdirSync(dir, { recursive: true });
    fs.copyFileSync(HANDLER, path.join(dir, 'index.js'));
    fs.copyFileSync(SHARED, path.join(dir, 'identity.js'));
    const entry = path.join(dir, 'index.js');
    delete require.cache[entry];
    delete require.cache[path.join(dir, 'identity.js')];
    return require(entry);
  })();
  assert.deepStrictEqual(
    await broken.handler(req({ token: sign(claims()) })),
    { isAuthorized: false },
    'a package with no config file fails closed',
  );

  global.fetch = originalFetch;
  console.log('http-api identity authorizer tests passed');
};
