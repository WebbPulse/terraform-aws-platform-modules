/**
 * Covers a browser holding sessions from two gates whose cookie domains nest, for
 * example production at example.com and staging at staging.example.com. The
 * browser sends the parent's CloudFront-* cookies to the child as well, and
 * CloudFront refuses any request that carries two sets.
 */

const assert = require('node:assert');
const crypto = require('node:crypto');

/** Returns the Set-Cookie values in `cookies` that expire `name` on `domain`. */
function clears(cookies, name, domain) {
  return cookies.filter((c) => c.startsWith(`${name}=;`) && c.includes(`Domain=${domain};`) && c.includes('Max-Age=0'));
}

/** Viewer function: a duplicated session cookie is never taken for a live session. */
async function gateTests(gate, ev, policyCookie) {
  const live = Math.floor(Date.now() / 1000) + 3600;
  const single = {
    'CloudFront-Policy': { value: policyCookie(live) },
    'CloudFront-Signature': { value: 'sig' },
    'CloudFront-Key-Pair-Id': { value: 'KPUB1' },
  };
  let r = await gate.handler(ev('/about', { cookies: single }));
  assert.strictEqual(r.uri, '/about/index.html', 'one set still passes');

  for (const name of Object.keys(single)) {
    const doubled = { ...single, [name]: { value: single[name].value, multiValue: [{ value: single[name].value }, { value: 'other' }] } };
    r = await gate.handler(ev('/about', { cookies: doubled }));
    assert.strictEqual(r.statusCode, 302, `a duplicated ${name} goes to login`);
    assert.strictEqual(r.headers.location.value, '/_auth/login?next=' + encodeURIComponent('/about'));
    r = await gate.handler(ev('/api/cars', { cookies: doubled }));
    assert.strictEqual(r.statusCode, 401, `a duplicated ${name} on the API answers 401`);
  }

  const oneValueMulti = { ...single, 'CloudFront-Policy': { value: single['CloudFront-Policy'].value, multiValue: [{ value: single['CloudFront-Policy'].value }] } };
  r = await gate.handler(ev('/about', { cookies: oneValueMulti }));
  assert.strictEqual(r.uri, '/about/index.html', 'a multiValue of one is not a duplicate');

  console.log('cookie collision gate function tests passed');
}

/** Login Lambda: a foreign set is expired on every parent domain, and only then. */
async function loginTests(login, mk) {
  const own = ['CloudFront-Policy=p', 'CloudFront-Signature=s', 'CloudFront-Key-Pair-Id=KPUB1'];
  const foreign = ['CloudFront-Policy=fp', 'CloudFront-Signature=fs', 'CloudFront-Key-Pair-Id=KPARENT'];

  let r = await login.handler(mk('/_auth/login', { next: '/' }));
  assert.strictEqual(r.cookies.length, 1, 'no foreign cookies, no eviction');
  r = await login.handler(mk('/_auth/login', { next: '/' }, own));
  assert.strictEqual(r.cookies.length, 1, 'this gate\'s own cookies are not a collision');

  r = await login.handler(mk('/_auth/login', { next: '/' }, foreign));
  assert(r.cookies[0].startsWith('__gate_state='), 'the state cookie stays first');
  for (const name of ['CloudFront-Policy', 'CloudFront-Signature', 'CloudFront-Key-Pair-Id']) {
    assert.strictEqual(clears(r.cookies, name, 'example.com').length, 1, `${name} is expired on the parent domain`);
    assert.strictEqual(clears(r.cookies, name, 'staging.example.com').length, 0, `${name} is not expired on this gate's own domain`);
  }
  assert.strictEqual(r.cookies.length, 4);
  assert(r.cookies.slice(1).every((c) => c.includes('Path=/;') && c.includes('Secure') && c.includes('HttpOnly')), 'the eviction matches the path the parent set');

  r = await login.handler(mk('/_auth/login', { next: '/' }, [...own, ...foreign]));
  assert.strictEqual(r.cookies.length, 4, 'two sets are a collision even when one is ours');
  r = await login.handler(mk('/_auth/login', { next: '/' }, [...own, 'CloudFront-Policy=stale']));
  assert.strictEqual(r.cookies.length, 4, 'a second value of any of the three names is a collision');

  const saved = process.env.COOKIE_DOMAIN;
  process.env.COOKIE_DOMAIN = 'staging.app.example.com';
  r = await login.handler(mk('/_auth/login', { next: '/' }, foreign));
  process.env.COOKIE_DOMAIN = saved;
  assert.strictEqual(clears(r.cookies, 'CloudFront-Key-Pair-Id', 'app.example.com').length, 1, 'the nearest parent is covered');
  assert.strictEqual(clears(r.cookies, 'CloudFront-Key-Pair-Id', 'example.com').length, 1, 'every parent above it is covered');
  assert.strictEqual(r.cookies.length, 7, 'two parents, three names each, plus the state cookie');
  assert(!r.cookies.some((c) => c.includes('Domain=com;')), 'a single label domain is never targeted');

  r = await login.handler(mk('/_auth/login', { next: '/next' }, foreign));
  const location = new URL(r.headers.location);
  const stateCookie = r.cookies[0].split(';')[0];
  const idPayload = Buffer.from(JSON.stringify({ iss: process.env.COGNITO_ISSUER, aud: 'cid', token_use: 'id', exp: Math.floor(Date.now() / 1000) + 600, email: 'me@example.com' })).toString('base64url');
  global.fetch = async () => ({ ok: true, status: 200, json: async () => ({ id_token: `h.${idPayload}.s` }) });
  r = await login.handler(mk('/_auth/callback', { code: 'c', state: location.searchParams.get('state') }, [stateCookie, ...foreign]));
  assert.strictEqual(r.statusCode, 302);
  assert.strictEqual(clears(r.cookies, 'CloudFront-Signature', 'example.com').length, 1, 'the callback evicts a foreign set too');
  const issued = r.cookies.filter((c) => c.includes('Domain=staging.example.com') && !c.includes('Max-Age=0'));
  assert.strictEqual(issued.length, 3, 'the callback still issues this gate\'s set');
  const lastEviction = r.cookies.map((c) => c.includes('Max-Age=0') && c.includes('Domain=example.com;')).lastIndexOf(true);
  const firstIssued = r.cookies.indexOf(issued[0]);
  assert(lastEviction < firstIssued, 'evictions come before the new set');

  console.log('cookie collision login tests passed');
}

/** Authorizer: the set whose key pair and signature are this gate's wins, whatever else is present. */
async function authorizerTests(auth, gateCookies, signPolicy) {
  const live = Math.floor(Date.now() / 1000) + 3600;
  const good = gateCookies(signPolicy(live));
  const parentKey = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey.export({ type: 'pkcs1', format: 'pem' });
  const parentPolicy = JSON.stringify({ Statement: [{ Resource: 'https://*example.com/*', Condition: { DateLessThan: { 'AWS:EpochTime': live } } }] });
  const cfsafe = (b) => b.toString('base64').replace(/\+/g, '-').replace(/=/g, '_').replace(/\//g, '~');
  const parent = [
    `CloudFront-Policy=${cfsafe(Buffer.from(parentPolicy))}`,
    `CloudFront-Signature=${cfsafe(crypto.createSign('RSA-SHA1').update(parentPolicy).sign(parentKey))}`,
    'CloudFront-Key-Pair-Id=KPARENT',
  ];
  const req = (cookies) => ({ requestContext: { http: { method: 'GET' } }, headers: {}, cookies });
  const reqHeader = (cookies) => ({ requestContext: { http: { method: 'GET' } }, headers: { cookie: cookies.join('; ') } });

  assert.deepStrictEqual(await auth.handler(req([...parent, ...good])), { isAuthorized: true }, 'parent set first, own set second');
  assert.deepStrictEqual(await auth.handler(req([...good, ...parent])), { isAuthorized: true }, 'own set first, parent set second');
  assert.deepStrictEqual(await auth.handler(req([parent[0], good[0], parent[1], good[1], parent[2], good[2]])), { isAuthorized: true }, 'interleaved sets');
  assert.deepStrictEqual(await auth.handler(reqHeader([...parent, ...good])), { isAuthorized: true }, 'both sets in a raw cookie header');
  assert.deepStrictEqual(await auth.handler(req(parent)), { isAuthorized: false }, 'the parent set alone is refused');
  assert.deepStrictEqual(await auth.handler(req([parent[0], parent[1], good[2]])), { isAuthorized: false }, 'this key pair id beside a foreign policy and signature is refused');
  assert.deepStrictEqual(await auth.handler(req([good[0], good[1], parent[2]])), { isAuthorized: false }, 'a valid pair under a foreign key pair id alone is refused');
  const stale = gateCookies(signPolicy(Math.floor(Date.now() / 1000) - 5));
  assert.deepStrictEqual(await auth.handler(req([...stale, ...parent])), { isAuthorized: false }, 'an expired own set is not rescued by a live foreign one');

  const flood = [];
  for (let i = 0; i < 10; i += 1) {
    flood.push(`CloudFront-Policy=junk${i}`, `CloudFront-Signature=junk${i}`);
  }
  assert.deepStrictEqual(await auth.handler(req([...flood, ...good])), { isAuthorized: false }, 'values past the per-name cap are not tried');

  console.log('cookie collision authorizer tests passed');
}

module.exports = { gateTests, loginTests, authorizerTests };
