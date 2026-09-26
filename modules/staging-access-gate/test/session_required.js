/**
 * Covers the page the distribution's 403 custom error response serves: it runs the
 * page's script against a stand-in browser and follows the redirect into login.
 */

const assert = require('node:assert');
const vm = require('node:vm');

/** Runs the page script as a browser at `pathname` + `search` would, returning where it navigated. */
function runPage(body, { pathname, search = '', storage = {}, now = 1_000_000, storageThrows = false }) {
  const script = body.match(/<script>([\s\S]*)<\/script>/)[1];
  const link = { href: '' };
  let replaced = null;
  const sessionStorage = {
    getItem: (k) => { if (storageThrows) throw new Error('blocked'); return k in storage ? storage[k] : null; },
    setItem: (k, v) => { if (storageThrows) throw new Error('blocked'); storage[k] = v; },
    removeItem: (k) => { delete storage[k]; },
  };
  const context = {
    location: { pathname, search, replace: (u) => { replaced = u; } },
    document: { getElementById: (id) => (id === 'l' ? link : null) },
    sessionStorage,
    Date: { now: () => now },
    encodeURIComponent,
    Number,
    String,
  };
  vm.runInNewContext(script, context);
  return { replaced, href: link.href, storage };
}

module.exports = async (login, mk) => {
  const r = await login.handler(mk('/_auth/session-required'));
  assert.strictEqual(r.statusCode, 200, 'the origin answers 200; the custom error response sets the 403');
  assert.strictEqual(r.headers['content-type'], 'text/html; charset=utf-8');
  assert.strictEqual(r.headers['cache-control'], 'no-store');
  assert(r.body.includes('<a id="l" href="/_auth/login">Sign in</a>'), 'the page works as a plain link without script');
  assert(!r.body.includes('index.html'), 'the page is not the SPA shell');

  const deep = runPage(r.body, { pathname: '/workspaces/ws-1', search: '?tab=runs&q=a b' });
  const expected = '/_auth/login?next=' + encodeURIComponent('/workspaces/ws-1?tab=runs&q=a b');
  assert.strictEqual(deep.replaced, expected, 'a deep link goes to login with its path and query as next');
  assert.strictEqual(deep.href, expected);

  const asset = runPage(r.body, { pathname: '/assets/index-abc123.js' });
  assert.strictEqual(asset.replaced, '/_auth/login?next=' + encodeURIComponent('/assets/index-abc123.js'));

  const loginResponse = await login.handler(mk('/_auth/login', { next: new URL(deep.replaced, 'https://www.staging.example.com').searchParams.get('next') }));
  const stored = loginResponse.cookies[0].split(';')[0].split('=')[1].split('.')[1];
  assert.strictEqual(Buffer.from(stored, 'base64url').toString(), '/workspaces/ws-1?tab=runs&q=a b', 'login keeps the next the page sent');

  const first = runPage(r.body, { pathname: '/workspaces', now: 5_000_000 });
  assert(first.replaced, 'the first bounce redirects');
  const second = runPage(r.body, { pathname: '/workspaces', now: 5_010_000, storage: first.storage });
  assert.strictEqual(second.replaced, null, 'a second bounce inside the window stops on the page instead of looping');
  assert.strictEqual(second.href, '/_auth/login?next=' + encodeURIComponent('/workspaces'), 'the stopped page still links to login with next');
  const later = runPage(r.body, { pathname: '/workspaces', now: 5_030_000, storage: first.storage });
  assert(later.replaced, 'a bounce after the window redirects again');

  const blocked = runPage(r.body, { pathname: '/workspaces', storageThrows: true });
  assert(blocked.replaced, 'blocked storage still redirects');

  const underAuth = runPage(r.body, { pathname: '/_auth/callback', search: '?code=x' });
  assert.strictEqual(underAuth.replaced, null, 'a 403 under the auth prefix shows the page rather than redirecting');

  const head = await login.handler({ ...mk('/_auth/session-required'), requestContext: { http: { method: 'HEAD' } } });
  assert.strictEqual(head.statusCode, 200);

  console.log('session required page tests passed');
};
