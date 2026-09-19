/**
 * Unit tests for the identity access token half of the gate authorizer.
 * Fully local: keys are generated in process and the JWKS fetch is stubbed.
 */

const assert = require('node:assert');
const crypto = require('node:crypto');
const ssmMod = require('@aws-sdk/client-ssm');
const { loadAuthorizer, loadAuthorizerWithRawConfig } = require('./package.js');

const ISSUER = 'https://api.staging.example.com/api/auth';
const AUDIENCE = 'example-staging-api';
const PROTECTED = 'GET /api/auth/me';
const OPEN = 'POST /api/auth/login';

const GUARD_ONE = 'GET /api/reports/count';
const GUARD_TWO = 'GET /api/health';
const PREFIX_SIBLING = 'GET /api/reports/{id}';

const signer = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const foreign = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });

const KID = 'key-one';
const ROTATED_KID = 'key-two';
const rotated = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });

/** Exports a public key as a JWKS entry with the given kid. */
function jwk(publicKey, kid) {
  return { ...publicKey.export({ format: 'jwk' }), kid, alg: 'RS256', use: 'sig' };
}

/** Signs claims into a compact JWT, allowing a forged alg or key for the negative cases. */
function sign(claims, { key = signer.privateKey, kid = KID, alg = 'RS256' } = {}) {
  const header = Buffer.from(JSON.stringify({ alg, kid, typ: 'JWT' })).toString('base64url');
  const payload = Buffer.from(JSON.stringify(claims)).toString('base64url');
  const signature = crypto
    .sign('RSA-SHA256', Buffer.from(`${header}.${payload}`, 'utf8'), key)
    .toString('base64url');
  return `${header}.${payload}.${signature}`;
}

const now = () => Math.floor(Date.now() / 1000);

/** Builds a valid claim set for this issuer and audience. */
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

/** Runs the identity access token assertions against the packaged authorizer. */
module.exports = async function run({ gateCookies, signPolicy, publicPem }) {
  process.env.HEADER_NAME = 'x-origin-verify';
  process.env.ORIGIN_VERIFY_PARAM = '/o';
  process.env.KEY_PAIR_ID = 'KPUB1';
  process.env.COOKIE_DOMAIN = 'staging.example.com';
  process.env.IDENTITY_ISSUER = ISSUER;
  process.env.IDENTITY_AUDIENCE = AUDIENCE;
  process.env.IDENTITY_JWKS_TTL_SECONDS = '300';
  delete process.env.SIGNING_PUBLIC_KEY_PEM;
  delete process.env.IDENTITY_JWT_ROUTE_KEYS;

  const ENFORCED = [PROTECTED, 'ANY /api/v1/{proxy+}', PREFIX_SIBLING];
  const auth = loadAuthorizer({ routeKeys: ENFORCED, signingPublicKeyPem: publicPem });

  assert.deepStrictEqual(
    auth.enforcedRouteKeys(),
    [...ENFORCED].sort(),
    'the enforced route keys are the ones the package was built with',
  );
  assert.strictEqual(
    process.env.IDENTITY_JWT_ROUTE_KEYS,
    undefined,
    'no environment variable carries the route key list',
  );
  assert.strictEqual(
    process.env.SIGNING_PUBLIC_KEY_PEM,
    undefined,
    'no environment variable carries the signing public key',
  );

  let served = [jwk(signer.publicKey, KID)];
  let fetches = 0;
  let failNext = false;
  let lastFetchHeaders = null;
  let gated = false;
  globalThis.fetch = async (url, init = {}) => {
    assert.strictEqual(url, `${ISSUER}/.well-known/jwks.json`, 'JWKS URL is derived from the issuer');
    fetches += 1;
    lastFetchHeaders = init.headers || {};
    if (failNext) {
      failNext = false;
      return { ok: false, status: 503, json: async () => ({}) };
    }
    if (gated && lastFetchHeaders['x-origin-verify'] !== 'S3CRET') {
      return { ok: false, status: 403, json: async () => ({ message: 'Forbidden' }) };
    }
    return { ok: true, status: 200, json: async () => ({ keys: served }) };
  };

  const live = () => signPolicy(now() + 3600);
  const req = (routeKey, token, opts = {}) => ({
    version: '2.0',
    routeKey,
    requestContext: { http: { method: opts.method || 'GET' }, routeKey },
    headers: token === null ? {} : { authorization: `Bearer ${token}` },
    cookies: opts.noGate ? undefined : gateCookies(live()),
  });

  const fresh = () => {
    auth.resetJwksCache();
    fetches = 0;
  };

  fresh();
  let r = await auth.handler(req(PROTECTED, sign(claims())));
  assert.strictEqual(r.isAuthorized, true, 'a valid token on a protected route is allowed');
  assert(r.context, 'an allowed protected request carries a context');

  const emitted = JSON.parse(r.context['jwt.claims']);
  assert.strictEqual(emitted.sub, 'user-123', 'sub is carried through');
  assert.strictEqual(emitted.email, 'me@example.com', 'a string claim stays a bare string');
  assert.strictEqual(typeof emitted.exp, 'string', 'exp is a string, as the native authorizer delivers it');
  assert(/^\d{10}$/.test(emitted.exp), 'exp is the epoch seconds the token carried, stringified');
  assert.strictEqual(emitted.roles, '["admin","user"]', 'a non-string claim is JSON encoded rather than dropped');
  assert.strictEqual(r.context['jwt.claims.sub'], 'user-123', 'the lifted sub matches');
  assert.strictEqual(r.context['jwt.claims.iss'], ISSUER, 'the lifted iss matches');

  for (const [k, v] of Object.entries(r.context)) {
    assert.strictEqual(typeof v, 'string', `context value ${k} must be a string`);
  }

  fresh();
  r = await auth.handler(req(OPEN, null));
  assert.deepStrictEqual(r, { isAuthorized: true }, 'a route not in the list needs no token');
  assert.strictEqual(fetches, 0, 'an open route does not fetch the JWKS at all');

  for (const guard of [GUARD_ONE, GUARD_TWO]) {
    fresh();
    r = await auth.handler(req(guard, null));
    assert.deepStrictEqual(r, { isAuthorized: true }, `${guard} is an anonymous guard route and needs no token`);
    assert.strictEqual(fetches, 0, `${guard} does not fetch the JWKS`);
  }

  fresh();
  r = await auth.handler(req(PREFIX_SIBLING, null));
  assert.deepStrictEqual(r, { isAuthorized: false }, 'the enforced sibling under the same prefix still requires a token');

  fresh();
  r = await auth.handler(req('POST /api/auth/me', null));
  assert.deepStrictEqual(r, { isAuthorized: true }, 'a different method on an enforced path is a different route key');

  for (const near of ['GET /api/auth', 'GET /api/auth/me/extra', 'GET /api/auth/mex']) {
    fresh();
    r = await auth.handler(req(near, null));
    assert.deepStrictEqual(r, { isAuthorized: true }, `${near} is not the enforced key and is not enforced`);
  }

  fresh();
  r = await auth.handler(req(PROTECTED, null));
  assert.deepStrictEqual(r, { isAuthorized: false }, 'a protected route with no bearer token is denied');

  fresh();
  r = await auth.handler({ ...req(PROTECTED, null), headers: { authorization: 'Basic abc' } });
  assert.deepStrictEqual(r, { isAuthorized: false }, 'a non-bearer Authorization header is denied');

  fresh();
  r = await auth.handler({ ...req(PROTECTED, null), headers: { authorization: 'Bearer not.a.jwt' } });
  assert.deepStrictEqual(r, { isAuthorized: false }, 'an undecodable token is denied');

  fresh();
  r = await auth.handler(req(PROTECTED, sign(claims({ exp: now() - 3600 }))));
  assert.deepStrictEqual(r, { isAuthorized: false }, 'an expired token is denied');

  fresh();
  r = await auth.handler(req(PROTECTED, sign(claims({ nbf: now() + 3600 }))));
  assert.deepStrictEqual(r, { isAuthorized: false }, 'a not-yet-valid token is denied');

  fresh();
  r = await auth.handler(req(PROTECTED, sign(claims({ exp: now() - 2 }))));
  assert.strictEqual(r.isAuthorized, true, 'a token just inside the clock skew allowance is accepted');

  fresh();
  r = await auth.handler(req(PROTECTED, sign(claims({ iss: 'https://evil.example.com/api/auth' }))));
  assert.deepStrictEqual(r, { isAuthorized: false }, 'a token from another issuer is denied');

  fresh();
  r = await auth.handler(req(PROTECTED, sign(claims({ aud: 'example-production-api' }))));
  assert.deepStrictEqual(r, { isAuthorized: false }, 'a production token is denied in staging');

  fresh();
  r = await auth.handler(req(PROTECTED, sign(claims({ aud: ['something-else', AUDIENCE] }))));
  assert.strictEqual(r.isAuthorized, true, 'an aud array containing the audience is accepted');

  fresh();
  r = await auth.handler(req(PROTECTED, sign(claims(), { key: foreign.privateKey })));
  assert.deepStrictEqual(r, { isAuthorized: false }, 'a token signed by a key not in the JWKS is denied');

  fresh();
  const unsignedHeader = Buffer.from(JSON.stringify({ alg: 'none', kid: KID, typ: 'JWT' })).toString('base64url');
  const unsignedPayload = Buffer.from(JSON.stringify(claims())).toString('base64url');
  r = await auth.handler(req(PROTECTED, `${unsignedHeader}.${unsignedPayload}.`));
  assert.deepStrictEqual(r, { isAuthorized: false }, 'alg none is denied');

  fresh();
  const hsHeader = Buffer.from(JSON.stringify({ alg: 'HS256', kid: KID, typ: 'JWT' })).toString('base64url');
  const hsSig = crypto.createHmac('sha256', publicPem).update(`${hsHeader}.${unsignedPayload}`).digest('base64url');
  r = await auth.handler(req(PROTECTED, `${hsHeader}.${unsignedPayload}.${hsSig}`));
  assert.deepStrictEqual(r, { isAuthorized: false }, 'an HMAC token is denied, whatever it is keyed with');

  fresh();
  await auth.handler(req(PROTECTED, sign(claims())));
  assert.strictEqual(fetches, 1, 'the first verification fetches the JWKS');
  await auth.handler(req(PROTECTED, sign(claims())));
  await auth.handler(req(PROTECTED, sign(claims())));
  assert.strictEqual(fetches, 1, 'the key set is cached across invocations within the TTL');

  served = [jwk(signer.publicKey, KID), jwk(rotated.publicKey, ROTATED_KID)];
  r = await auth.handler(req(PROTECTED, sign(claims(), { key: rotated.privateKey, kid: ROTATED_KID })));
  assert.strictEqual(r.isAuthorized, true, 'a token signed by a newly rotated key is accepted after a refresh');
  assert.strictEqual(fetches, 2, 'an unknown kid triggers exactly one refetch, not a fetch per request');

  const before = fetches;
  r = await auth.handler(req(PROTECTED, sign(claims(), { key: foreign.privateKey, kid: 'no-such-key' })));
  assert.deepStrictEqual(r, { isAuthorized: false }, 'an unknown kid that is still unknown after a refresh is denied');
  assert.strictEqual(fetches, before + 1, 'a genuinely unknown kid costs one refetch');

  fresh();
  await auth.handler(req(PROTECTED, sign(claims())));
  assert.strictEqual(fetches, 1, 'cache primed');
  failNext = true;
  r = await auth.handler(req(PROTECTED, sign(claims(), { key: foreign.privateKey, kid: 'no-such-key' })));
  assert.deepStrictEqual(r, { isAuthorized: false }, 'the unknown kid is still denied when the refresh fails');
  r = await auth.handler(req(PROTECTED, sign(claims())));
  assert.strictEqual(r.isAuthorized, true, 'a known key still verifies against the cached set after a failed refresh');

  fresh();
  r = await auth.handler(req(PROTECTED, sign(claims()), { noGate: true }));
  assert.deepStrictEqual(r, { isAuthorized: false }, 'a valid token without the gate cookies is denied');
  assert.strictEqual(fetches, 0, 'a request refused by the gate never reaches the token check');

  fresh();
  r = await auth.handler({
    ...req(PROTECTED, sign(claims())),
    cookies: gateCookies(signPolicy(now() - 5)),
  });
  assert.deepStrictEqual(r, { isAuthorized: false }, 'an expired gate cookie is denied even with a valid token');

  fresh();
  r = await auth.handler({ ...req(PROTECTED, null, { method: 'OPTIONS', noGate: true }) });
  assert.deepStrictEqual(r, { isAuthorized: true }, 'a CORS preflight is allowed on a protected route');

  const plain = loadAuthorizer({ routeKeys: [], signingPublicKeyPem: publicPem });
  fetches = 0;
  r = await plain.handler(req(PROTECTED, null));
  assert.deepStrictEqual(r, { isAuthorized: true }, 'with no route keys configured, no route requires a token');
  assert.strictEqual(fetches, 0, 'and the JWKS is never fetched');

  fresh();
  gated = true;
  r = await auth.handler(req(PROTECTED, sign(claims())));
  assert.strictEqual(
    r.isAuthorized,
    true,
    'a valid token is accepted even when the JWKS endpoint is itself behind the gate',
  );
  assert.strictEqual(
    lastFetchHeaders['x-origin-verify'],
    'S3CRET',
    'the JWKS fetch presents the origin verification header the authorizer already holds',
  );

  ssmMod.SSMClient.prototype.send = async () => ({ Parameter: { Value: 'NOT-THE-GATE-SECRET' } });
  const mismatched = loadAuthorizer({ routeKeys: ENFORCED, signingPublicKeyPem: publicPem });
  mismatched.resetJwksCache();
  gated = true;
  r = await mismatched.handler({
    version: '2.0',
    routeKey: PROTECTED,
    requestContext: { http: { method: 'GET' }, routeKey: PROTECTED },
    headers: { authorization: `Bearer ${sign(claims())}`, 'x-origin-verify': 'NOT-THE-GATE-SECRET' },
  });
  assert.deepStrictEqual(
    r,
    { isAuthorized: false },
    'when the JWKS fetch cannot authenticate, the token is denied and the failure is closed',
  );
  gated = false;
  ssmMod.SSMClient.prototype.send = async () => ({ Parameter: { Value: 'S3CRET' } });

  const anon = loadAuthorizer({
    routeKeys: ENFORCED,
    signingPublicKeyPem: publicPem,
    anonymousPathPrefixes: ['/api/auth/.well-known/'],
  });

  assert.deepStrictEqual(
    anon.anonymousPathPrefixes(),
    ['/api/auth/.well-known/'],
    'the exempt prefixes come from the package',
  );

  const wellKnown = (rawPath) => ({
    version: '2.0',
    rawPath,
    routeKey: 'GET /api/auth/{proxy+}',
    requestContext: { http: { method: 'GET', path: rawPath }, routeKey: 'GET /api/auth/{proxy+}' },
    headers: {},
  });

  for (const path of [
    '/api/auth/.well-known/jwks.json',
    '/api/auth/.well-known/openid-configuration',
  ]) {
    r = await anon.handler(wellKnown(path));
    assert.deepStrictEqual(
      r,
      { isAuthorized: true },
      `${path} is admitted with no gate credential and no token`,
    );
  }

  for (const path of [
    '/api/auth/login',
    '/api/auth/.well-knownish/secrets',
    '/api/auth',
    '/api/users/me',
    '/',
  ]) {
    r = await anon.handler(wellKnown(path));
    assert.deepStrictEqual(
      r,
      { isAuthorized: false },
      `${path} is not exempt and is still refused without a gate credential`,
    );
  }

  r = await auth.handler(wellKnown('/api/auth/.well-known/jwks.json'));
  assert.deepStrictEqual(
    r,
    { isAuthorized: false },
    'with no exempt prefixes rendered, the well-known paths are gated as before',
  );

  const API_KEY = 'wpk_live_abc123def456';

  const keyed = loadAuthorizer({
    routeKeys: ENFORCED,
    signingPublicKeyPem: publicPem,
    apiKeyPrefixes: ['wpk_'],
  });

  assert.deepStrictEqual(
    keyed.apiKeyPrefixes(),
    ['wpk_'],
    'the API key prefixes come from the package',
  );

  keyed.resetJwksCache();
  fetches = 0;
  r = await keyed.handler(req(PROTECTED, API_KEY));
  assert.deepStrictEqual(
    r,
    { isAuthorized: true },
    'an API key bearer on an enforced route is allowed through with no claims context',
  );
  assert.strictEqual(fetches, 0, 'a passed-through key never fetches the JWKS');

  keyed.resetJwksCache();
  fetches = 0;
  r = await keyed.handler(req(PROTECTED, sign(claims())));
  assert.strictEqual(r.isAuthorized, true, 'a real JWT still verifies when prefixes are configured');
  assert.strictEqual(
    JSON.parse(r.context['jwt.claims']).sub,
    'user-123',
    'and it still arrives with its claims context',
  );

  keyed.resetJwksCache();
  fetches = 0;
  r = await keyed.handler(req(OPEN, API_KEY));
  assert.deepStrictEqual(
    r,
    { isAuthorized: true },
    'a route outside the enforced keys is allowed as before, prefixes or not',
  );
  assert.strictEqual(fetches, 0, 'and it never reaches the token check');

  keyed.resetJwksCache();
  r = await keyed.handler(req(PROTECTED, 'wpq_not_a_configured_prefix'));
  assert.deepStrictEqual(
    r,
    { isAuthorized: false },
    'a bearer matching no configured prefix and verifying as no JWT is denied',
  );

  keyed.resetJwksCache();
  r = await keyed.handler(req(PROTECTED, null));
  assert.deepStrictEqual(
    r,
    { isAuthorized: false },
    'a missing bearer is still denied on an enforced route with prefixes configured',
  );

  fresh();
  r = await auth.handler(req(PROTECTED, API_KEY));
  assert.deepStrictEqual(
    r,
    { isAuthorized: false },
    'with no prefixes configured, an API key bearer is denied as before',
  );

  keyed.resetJwksCache();
  r = await keyed.handler(req(PROTECTED, API_KEY, { noGate: true }));
  assert.deepStrictEqual(
    r,
    { isAuthorized: false },
    'a matching prefix does not get past the gate credential check',
  );

  keyed.resetJwksCache();
  r = await keyed.handler({
    ...req(PROTECTED, API_KEY),
    cookies: gateCookies(signPolicy(now() - 5)),
  });
  assert.deepStrictEqual(
    r,
    { isAuthorized: false },
    'an expired gate cookie denies a matching prefix too',
  );

  const oldPackage = loadAuthorizerWithRawConfig({
    route_keys: [...ENFORCED].sort(),
    signing_public_key_pem: publicPem,
    anonymous_path_prefixes: [],
  });
  assert.deepStrictEqual(
    oldPackage.apiKeyPrefixes(),
    [],
    'a config with no api_key_prefixes key reads as no prefixes',
  );
  oldPackage.resetJwksCache();
  r = await oldPackage.handler(req(PROTECTED, API_KEY));
  assert.deepStrictEqual(
    r,
    { isAuthorized: false },
    'and such a package keeps failing closed on an API key bearer',
  );

  console.log('identity jwt api key passthrough tests passed');

  const savedFetch = globalThis.fetch;

  /**
   * Serves the JWKS after `delayMs`, honouring the abort signal exactly as the
   * runtime's fetch does, so a fetch past its deadline rejects rather than resolving late.
   */
  const slowJwks = (delayMs, onAttempt = () => {}) => async (url, init = {}) => {
    onAttempt();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => resolve({ ok: true, status: 200, json: async () => ({ keys: served }) }), delayMs);
      const signal = init.signal;
      if (signal) {
        signal.addEventListener('abort', () => {
          clearTimeout(timer);
          const err = new Error('This operation was aborted');
          err.name = 'AbortError';
          reject(err);
        });
      }
    });
  };

  const TIMEOUT_MS = 600;

  const timed = loadAuthorizer({
    routeKeys: ENFORCED,
    signingPublicKeyPem: publicPem,
    jwksFetchTimeoutMs: TIMEOUT_MS,
  });

  timed.resetJwksCache();
  globalThis.fetch = slowJwks(TIMEOUT_MS - 250);
  r = await timed.handler(req(PROTECTED, sign(claims())));
  assert.strictEqual(
    r.isAuthorized,
    true,
    'a JWKS fetch that resolves just inside the configured timeout verifies the token and is allowed',
  );

  timed.resetJwksCache();
  let slowAttempts = 0;
  globalThis.fetch = slowJwks(TIMEOUT_MS * 4, () => {
    slowAttempts += 1;
  });
  r = await timed.handler(req(PROTECTED, sign(claims())));
  assert.deepStrictEqual(
    r,
    { isAuthorized: false },
    'a JWKS fetch that outruns the configured timeout is aborted and the token is denied, failing closed',
  );
  assert.strictEqual(slowAttempts, 2, 'the aborted fetch is retried exactly once inside the same invocation');

  timed.resetJwksCache();
  let coldAttempts = 0;
  globalThis.fetch = async (url, init = {}) => {
    coldAttempts += 1;
    if (coldAttempts === 1) {
      return slowJwks(TIMEOUT_MS * 4)(url, init);
    }
    return { ok: true, status: 200, json: async () => ({ keys: served }) };
  };
  r = await timed.handler(req(PROTECTED, sign(claims())));
  assert.strictEqual(
    r.isAuthorized,
    true,
    'a cold first fetch that aborts is retried once and the warm second attempt verifies the token',
  );
  assert.strictEqual(coldAttempts, 2, 'the warm retry is the second and last attempt');

  const defaulted = loadAuthorizerWithRawConfig({
    route_keys: [...ENFORCED].sort(),
    signing_public_key_pem: publicPem,
    anonymous_path_prefixes: [],
    api_key_prefixes: [],
  });
  defaulted.resetJwksCache();
  globalThis.fetch = slowJwks(2100);
  r = await defaulted.handler(req(PROTECTED, sign(claims())));
  assert.strictEqual(
    r.isAuthorized,
    true,
    'with no jwks_fetch_timeout_ms in the package the default covers a cold identity function serving the key set in about two seconds',
  );

  globalThis.fetch = savedFetch;

  console.log('identity jwt jwks fetch timeout tests passed');

  console.log('identity jwt authorizer tests passed');
};
