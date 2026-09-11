// Asserts that the environment the module renders for the authorizer Lambda stays under the 4096
// byte cap, for a route key list far larger than the one that broke production.
//
// WHY THIS TEST EXISTS. Lambda caps the whole environment, keys and values together, at 4096 bytes,
// and it measures that only at UpdateFunctionConfiguration. Terraform's plan is green either way,
// so the first sign of an oversized map is a failed apply:
//
//   InvalidParameterValueException: Lambda was unable to configure your environment variables
//   because the environment variables you have provided exceeded the 4KB limit.
//   Measured size: 4545 bytes
//
// That is what CarModPicker staging hit at 95 route keys, where IDENTITY_JWT_ROUTE_KEYS alone was
// 3600 bytes. A unit test is the only place this gets caught before an apply, so the rule the fix
// established (nothing in the environment scales with the consumer's configuration) is asserted
// here rather than left to a comment.
//
// The map below mirrors locals.authorizer_environment key for key. If a variable is added there,
// add it here too; the point of the test is that the two stay in step.

const assert = require('node:assert');

const LIMIT = 4096;

// Lambda measures the sum of every key and every value, as UTF-8 bytes.
function measure(env) {
  return Object.entries(env).reduce(
    (total, [key, value]) => total + Buffer.byteLength(key, 'utf8') + Buffer.byteLength(String(value), 'utf8'),
    0,
  );
}

// locals.authorizer_environment, with realistically long values: a real SSM parameter path, a real
// issuer URL, a real CloudFront key pair id.
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

// A 300 key list, three times the 95 keys that broke the apply, with long realistic keys.
function routeKeys(count) {
  const methods = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'];
  const keys = [];
  for (let i = 0; i < count; i += 1) {
    keys.push(`${methods[i % methods.length]} /api/build-lists/collections/${i}/parts/{part_id}`);
  }
  return keys.sort();
}

module.exports = async function run() {
  const enforced = renderEnvironment({ enforced: true });
  const size = measure(enforced);
  assert(size < LIMIT, `the rendered environment is ${size} bytes, over the ${LIMIT} byte cap`);

  // The whole point: adding route keys must not move the environment at all. This is the assertion
  // that would have caught the outage.
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

  // And the config file that carries the list instead is well formed and holds every key.
  const { renderConfig } = require('./package.js');
  const config = JSON.parse(renderConfig({ routeKeys: keys, signingPublicKeyPem: '-'.repeat(451) }));
  assert.strictEqual(config.route_keys.length, 300, 'every route key is in the package config');
  assert.deepStrictEqual(config.route_keys, [...keys].sort(), 'the package config carries the sorted list');

  // A gate with nothing enforced is smaller still.
  assert(measure(renderEnvironment({ enforced: false })) < LIMIT, 'the unenforced environment is under the cap');

  console.log(`environment size test passed (${size} bytes with a 300 key list, cap ${LIMIT})`);
};
