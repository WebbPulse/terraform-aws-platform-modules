/**
 * Asserts the authorizer Lambda environment stays under Lambda's 4096 byte cap and
 * does not grow with the route key list. Mirrors locals.authorizer_environment,
 * which only a failed apply would otherwise catch.
 */

const assert = require('node:assert');

const LIMIT = 4096;

/** Measures an environment the way Lambda does: every key and value as UTF-8 bytes. */
function measure(env) {
  return Object.entries(env).reduce(
    (total, [key, value]) => total + Buffer.byteLength(key, 'utf8') + Buffer.byteLength(String(value), 'utf8'),
    0,
  );
}

/** Mirrors locals.authorizer_environment with realistically long values. */
function renderEnvironment({ enforced = true } = {}) {
  const base = {
    HEADER_NAME: 'x-origin-verify',
    ORIGIN_VERIFY_PARAM: '/carmodpicker-staging/access-gate/origin-verify',
    COOKIE_DOMAIN: 'staging.carmodpicker.com',
    KEY_PAIR_ID: 'K1ABCDEFGHIJKLM',
  };
  if (!enforced) {
    return base;
  }
  return {
    ...base,
    IDENTITY_ISSUER: 'https://api.staging.carmodpicker.com/api/auth',
    IDENTITY_AUDIENCE: 'carmodpicker-staging-api',
    IDENTITY_JWKS_URL: 'https://api.staging.carmodpicker.com/api/auth/.well-known/jwks.json',
    IDENTITY_JWKS_TTL_SECONDS: '300',
    IDENTITY_CLOCK_SKEW_SECONDS: '60',
  };
}

/** Builds `count` realistically long route keys, sorted. */
function routeKeys(count) {
  const methods = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'];
  const keys = [];
  for (let i = 0; i < count; i += 1) {
    keys.push(`${methods[i % methods.length]} /api/build-lists/collections/${i}/parts/{part_id}`);
  }
  return keys.sort();
}

/** Runs the environment size assertions. */
module.exports = async function run() {
  const enforced = renderEnvironment({ enforced: true });
  const size = measure(enforced);
  assert(size < LIMIT, `the rendered environment is ${size} bytes, over the ${LIMIT} byte cap`);

  const keys = routeKeys(300);
  assert.strictEqual(keys.length, 300, 'the size test uses a 300 key list');
  const joined = keys.join(',');
  assert(
    Buffer.byteLength(joined, 'utf8') > LIMIT,
    'the 300 key list is bigger than the whole cap on its own, which is the situation being defended against',
  );
  assert.strictEqual(
    measure(enforced),
    size,
    'the rendered environment does not depend on the route key list',
  );

  const { renderConfig } = require('./package.js');
  const config = JSON.parse(renderConfig({ routeKeys: keys, signingPublicKeyPem: '-'.repeat(451) }));
  assert.strictEqual(config.route_keys.length, 300, 'every route key is in the package config');
  assert.deepStrictEqual(config.route_keys, [...keys].sort(), 'the package config carries the sorted list');

  assert(measure(renderEnvironment({ enforced: false })) < LIMIT, 'the unenforced environment is under the cap');

  console.log(`environment size test passed (${size} bytes with a 300 key list, cap ${LIMIT})`);
};
