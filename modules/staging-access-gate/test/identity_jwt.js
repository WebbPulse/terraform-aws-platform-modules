// Unit tests for the identity access token half of the gate authorizer.
//
// Everything is local: a throwaway RSA key pair is generated in-process, tokens are signed with it,
// and the JWKS fetch is stubbed on globalThis.fetch. No network, no AWS, no credentials.
//
// Run through test/run.js, which runs the gate and login suites first.

const assert = require('node:assert');
const crypto = require('node:crypto');
const { loadAuthorizer } = require('./package.js');

const ISSUER = 'https://api.staging.example.com/api/auth';
const AUDIENCE = 'example-staging-api';
const PROTECTED = 'GET /api/auth/me';
const OPEN = 'POST /api/auth/login';

// Two routes that sit under an enforced prefix and must stay anonymous. They are the reason the
// route key list is matched exactly and never by prefix: "GET /api/reports/count" answers
// unauthenticated callers while "GET /api/reports/{id}" requires a token, and both begin
// "GET /api/reports/".
const GUARD_ONE = 'GET /api/reports/count';
const GUARD_TWO = 'GET /api/health';
const PREFIX_SIBLING = 'GET /api/reports/{id}';

// The signing key the "identity function" uses, and a second one nothing trusts.
const signer = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const foreign = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });

const KID = 'key-one';
const ROTATED_KID = 'key-two';
const rotated = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });

function jwk(publicKey, kid) {
  return { ...publicKey.export({ format: 'jwk' }), kid, alg: 'RS256', use: 'sig' };
}

function sign(claims, { key = signer.privateKey, kid = KID, alg = 'RS256' } = {}) {
  const header = Buffer.from(JSON.stringify({ alg, kid, typ: 'JWT' })).toString('base64url');
  const payload = Buffer.from(JSON.stringify(claims)).toString('base64url');
  const signature = crypto
    .sign('RSA-SHA256', Buffer.from(`${header}.${payload}`, 'utf8'), key)
    .toString('base64url');
  return `${header}.${payload}.${signature}`;
}

const now = () => Math.floor(Date.now() / 1000);

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

module.exports = async function run({ gateCookies, signPolicy, publicPem }) {
  // The environment the Terraform module renders. The route key list and the signing public key are
  // no longer in it: they are rendered into identity_jwt_config.json inside the deployment package,
  // because the whole environment is capped at 4096 bytes and the list is what overran it.
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

  // --- the list comes from the package, not the environment ------------------------------------

  // What the handler is enforcing is exactly what the module rendered into the package, and it got
  // there with no environment variable carrying it.
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

  // The stubbed JWKS endpoint. `served` is what it returns and `fetches` counts calls, which is how
  // the caching and the unknown-kid refresh are asserted rather than assumed.
  let served = [jwk(signer.publicKey, KID)];
  let fetches = 0;
  let failNext = false;
  globalThis.fetch = async (url) => {
    assert.strictEqual(url, `${ISSUER}/.well-known/jwks.json`, 'JWKS URL is derived from the issuer');
    fetches += 1;
    if (failNext) {
      failNext = false;
      return { ok: false, status: 503, json: async () => ({}) };
    }
    return { ok: true, status: 200, json: async () => ({ keys: served }) };
  };

  // A request that already passes the gate, so every assertion below is about the token alone.
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

  // --- the happy path -------------------------------------------------------------------------

  fresh();
  let r = await auth.handler(req(PROTECTED, sign(claims())));
  assert.strictEqual(r.isAuthorized, true, 'a valid token on a protected route is allowed');
  assert(r.context, 'an allowed protected request carries a context');

  // The context mirrors the native JWT authorizer as closely as a Lambda authorizer can: one key
  // named jwt.claims holding every claim as a string, so exp is a string in both environments.
  const emitted = JSON.parse(r.context['jwt.claims']);
  assert.strictEqual(emitted.sub, 'user-123', 'sub is carried through');
  assert.strictEqual(emitted.email, 'me@example.com', 'a string claim stays a bare string');
  assert.strictEqual(typeof emitted.exp, 'string', 'exp is a string, as the native authorizer delivers it');
  assert(/^\d{10}$/.test(emitted.exp), 'exp is the epoch seconds the token carried, stringified');
  assert.strictEqual(emitted.roles, '["admin","user"]', 'a non-string claim is JSON encoded rather than dropped');
  assert.strictEqual(r.context['jwt.claims.sub'], 'user-123', 'the lifted sub matches');
  assert.strictEqual(r.context['jwt.claims.iss'], ISSUER, 'the lifted iss matches');

  // Every context value has to be a scalar: API Gateway rejects a nested object outright.
  for (const [k, v] of Object.entries(r.context)) {
    assert.strictEqual(typeof v, 'string', `context value ${k} must be a string`);
  }

  // --- an open route is untouched -------------------------------------------------------------

  fresh();
  r = await auth.handler(req(OPEN, null));
  assert.deepStrictEqual(r, { isAuthorized: true }, 'a route not in the list needs no token');
  assert.strictEqual(fetches, 0, 'an open route does not fetch the JWKS at all');

  // --- exact match, never prefix match -----------------------------------------------------------

  // The two anonymous guard routes stay anonymous even though one of them shares its whole path
  // prefix with an enforced route. Anything looser than an exact match breaks this, which is the
  // reason the list cannot be shortened by prefixes to fit in an environment variable.
  for (const guard of [GUARD_ONE, GUARD_TWO]) {
    fresh();
    r = await auth.handler(req(guard, null));
    assert.deepStrictEqual(r, { isAuthorized: true }, `${guard} is an anonymous guard route and needs no token`);
    assert.strictEqual(fetches, 0, `${guard} does not fetch the JWKS`);
  }

  // Its prefix sibling, which is in the list, is enforced.
  fresh();
  r = await auth.handler(req(PREFIX_SIBLING, null));
  assert.deepStrictEqual(r, { isAuthorized: false }, 'the enforced sibling under the same prefix still requires a token');

  // Method is part of the key: the same path under a different method is a different route and is
  // not enforced unless it is listed in its own right.
  fresh();
  r = await auth.handler(req('POST /api/auth/me', null));
  assert.deepStrictEqual(r, { isAuthorized: true }, 'a different method on an enforced path is a different route key');

  // And a key that is a strict prefix or a strict extension of an enforced one does not match.
  for (const near of ['GET /api/auth', 'GET /api/auth/me/extra', 'GET /api/auth/mex']) {
    fresh();
    r = await auth.handler(req(near, null));
    assert.deepStrictEqual(r, { isAuthorized: true }, `${near} is not the enforced key and is not enforced`);
  }

  // --- missing header when required -----------------------------------------------------------

  fresh();
  r = await auth.handler(req(PROTECTED, null));
  assert.deepStrictEqual(r, { isAuthorized: false }, 'a protected route with no bearer token is denied');

  // A present but malformed Authorization header is the same answer.
  fresh();
  r = await auth.handler({ ...req(PROTECTED, null), headers: { authorization: 'Basic abc' } });
  assert.deepStrictEqual(r, { isAuthorized: false }, 'a non-bearer Authorization header is denied');

  fresh();
  r = await auth.handler({ ...req(PROTECTED, null), headers: { authorization: 'Bearer not.a.jwt' } });
  assert.deepStrictEqual(r, { isAuthorized: false }, 'an undecodable token is denied');

  // --- expired, and not yet valid -------------------------------------------------------------

  fresh();
  r = await auth.handler(req(PROTECTED, sign(claims({ exp: now() - 3600 }))));
  assert.deepStrictEqual(r, { isAuthorized: false }, 'an expired token is denied');

  fresh();
  r = await auth.handler(req(PROTECTED, sign(claims({ nbf: now() + 3600 }))));
  assert.deepStrictEqual(r, { isAuthorized: false }, 'a not-yet-valid token is denied');

  // A token that expired two seconds ago is still accepted, because the skew allowance is 60s.
  // That allowance is deliberate and this asserts it rather than leaving it to be discovered.
  fresh();
  r = await auth.handler(req(PROTECTED, sign(claims({ exp: now() - 2 }))));
  assert.strictEqual(r.isAuthorized, true, 'a token just inside the clock skew allowance is accepted');

  // --- wrong issuer, wrong audience -----------------------------------------------------------

  fresh();
  r = await auth.handler(req(PROTECTED, sign(claims({ iss: 'https://evil.example.com/api/auth' }))));
  assert.deepStrictEqual(r, { isAuthorized: false }, 'a token from another issuer is denied');

  fresh();
  r = await auth.handler(req(PROTECTED, sign(claims({ aud: 'example-production-api' }))));
  assert.deepStrictEqual(r, { isAuthorized: false }, 'a production token is denied in staging');

  // aud as an array is valid per RFC 7519 and must be accepted when it contains ours.
  fresh();
  r = await auth.handler(req(PROTECTED, sign(claims({ aud: ['something-else', AUDIENCE] }))));
  assert.strictEqual(r.isAuthorized, true, 'an aud array containing the audience is accepted');

  // --- a forged signature ---------------------------------------------------------------------

  fresh();
  r = await auth.handler(req(PROTECTED, sign(claims(), { key: foreign.privateKey })));
  assert.deepStrictEqual(r, { isAuthorized: false }, 'a token signed by a key not in the JWKS is denied');

  // The alg is read to refuse, never to select. "none" and an HMAC both have to be refused even
  // though the claims are otherwise perfect.
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

  // --- the JWKS cache, and the unknown kid refresh ---------------------------------------------

  fresh();
  await auth.handler(req(PROTECTED, sign(claims())));
  assert.strictEqual(fetches, 1, 'the first verification fetches the JWKS');
  await auth.handler(req(PROTECTED, sign(claims())));
  await auth.handler(req(PROTECTED, sign(claims())));
  assert.strictEqual(fetches, 1, 'the key set is cached across invocations within the TTL');

  // A key rotation: the identity module adds a second signing key and starts signing with it. The
  // cached set does not have that kid, so the authorizer refetches once and accepts the token.
  served = [jwk(signer.publicKey, KID), jwk(rotated.publicKey, ROTATED_KID)];
  r = await auth.handler(req(PROTECTED, sign(claims(), { key: rotated.privateKey, kid: ROTATED_KID })));
  assert.strictEqual(r.isAuthorized, true, 'a token signed by a newly rotated key is accepted after a refresh');
  assert.strictEqual(fetches, 2, 'an unknown kid triggers exactly one refetch, not a fetch per request');

  // And a kid that is genuinely not there refetches once and then gives up, rather than refetching
  // on every subsequent request.
  const before = fetches;
  r = await auth.handler(req(PROTECTED, sign(claims(), { key: foreign.privateKey, kid: 'no-such-key' })));
  assert.deepStrictEqual(r, { isAuthorized: false }, 'an unknown kid that is still unknown after a refresh is denied');
  assert.strictEqual(fetches, before + 1, 'a genuinely unknown kid costs one refetch');

  // A failed refresh falls back to the cached set rather than taking the API down.
  fresh();
  await auth.handler(req(PROTECTED, sign(claims())));
  assert.strictEqual(fetches, 1, 'cache primed');
  failNext = true;
  r = await auth.handler(req(PROTECTED, sign(claims(), { key: foreign.privateKey, kid: 'no-such-key' })));
  assert.deepStrictEqual(r, { isAuthorized: false }, 'the unknown kid is still denied when the refresh fails');
  r = await auth.handler(req(PROTECTED, sign(claims())));
  assert.strictEqual(r.isAuthorized, true, 'a known key still verifies against the cached set after a failed refresh');

  // --- the gate still comes first ---------------------------------------------------------------

  // A perfect token with no gate credentials is refused. The token is an additional requirement and
  // never a way around the gate.
  fresh();
  r = await auth.handler(req(PROTECTED, sign(claims()), { noGate: true }));
  assert.deepStrictEqual(r, { isAuthorized: false }, 'a valid token without the gate cookies is denied');
  assert.strictEqual(fetches, 0, 'a request refused by the gate never reaches the token check');

  // A gate cookie set that has expired is refused on a protected route too.
  fresh();
  r = await auth.handler({
    ...req(PROTECTED, sign(claims())),
    cookies: gateCookies(signPolicy(now() - 5)),
  });
  assert.deepStrictEqual(r, { isAuthorized: false }, 'an expired gate cookie is denied even with a valid token');

  // A preflight is exempt: it carries no credentials of any kind by definition.
  fresh();
  r = await auth.handler({ ...req(PROTECTED, null, { method: 'OPTIONS', noGate: true }) });
  assert.deepStrictEqual(r, { isAuthorized: true }, 'a CORS preflight is allowed on a protected route');

  // --- enforcement off ---------------------------------------------------------------------------

  // An empty route key list in the package means the gate behaves exactly as it did before this
  // feature, which is the default every existing consumer gets.
  const plain = loadAuthorizer({ routeKeys: [], signingPublicKeyPem: publicPem });
  fetches = 0;
  r = await plain.handler(req(PROTECTED, null));
  assert.deepStrictEqual(r, { isAuthorized: true }, 'with no route keys configured, no route requires a token');
  assert.strictEqual(fetches, 0, 'and the JWKS is never fetched');

  console.log('identity jwt authorizer tests passed');
};
