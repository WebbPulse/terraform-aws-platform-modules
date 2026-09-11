const assert = require('node:assert');
const crypto = require('node:crypto');
const gate = require('./gate.rendered.js');
const { loadAuthorizer, loadAuthorizerWithoutConfig } = require('./package.js');

function cfsafe(b){return b.toString('base64').replace(/\+/g,'-').replace(/=/g,'_').replace(/\//g,'~');}
function policyCookie(exp){return cfsafe(Buffer.from(JSON.stringify({Statement:[{Resource:'https://*staging.example.com/*',Condition:{DateLessThan:{'AWS:EpochTime':exp}}}]})));}
function ev(uri, opts={}) {
  return { request: { uri, method:'GET', querystring: opts.qs||{}, headers: { host: { value: opts.host||'www.staging.example.com' } }, cookies: opts.cookies||{} } };
}
(async () => {
  // base64 roundtrip incl. non-multiple-of-3 lengths
  for (const s of ['a','ab','abc','abcd','{"x":1}', JSON.stringify({Statement:[{Resource:'https://*staging.example.com/*',Condition:{DateLessThan:{'AWS:EpochTime':1757200000}}}]})]) {
    assert.strictEqual(gate.decodePolicy(cfsafe(Buffer.from(s))), s, 'roundtrip '+s);
  }
  // no cookie -> redirect with next
  let r = await gate.handler(ev('/cars/12', {qs:{a:{value:'1 2'}, b:{multiValue:[{value:'x'},{value:'y'}]}}}));
  assert.strictEqual(r.statusCode, 302);
  assert.strictEqual(r.headers.location.value, '/_auth/login?next=' + encodeURIComponent('/cars/12?a=1%202&b=x&b=y'));
  // apex redirect from app handler wins
  r = await gate.handler(ev('/x', {host:'staging.example.com'}));
  assert.strictEqual(r.statusCode, 301);
  // live cookie -> request passes, rewritten by app handler
  const live = Math.floor(Date.now()/1000)+3600;
  const cookies = {'CloudFront-Policy':{value:policyCookie(live)}, 'CloudFront-Signature':{value:'sig'}, 'CloudFront-Key-Pair-Id':{value:'K1'}};
  r = await gate.handler(ev('/about', {cookies}));
  assert.strictEqual(r.uri, '/about/index.html');
  // expired cookie -> redirect
  const expiredCookies = {...cookies, 'CloudFront-Policy':{value:policyCookie(Math.floor(Date.now()/1000)-5)}};
  r = await gate.handler(ev('/about', {cookies: expiredCookies}));
  assert.strictEqual(r.statusCode, 302);
  // api without cookie -> 401 json, not rewritten
  r = await gate.handler(ev('/api/cars'));
  assert.strictEqual(r.statusCode, 401);
  // api with cookie -> passes, uri untouched
  r = await gate.handler(ev('/api/cars', {cookies}));
  assert.strictEqual(r.uri, '/api/cars');
  // auth prefix passes through with x-forwarded-host, no rewrite
  r = await gate.handler(ev('/_auth/login'));
  assert.strictEqual(r.uri, '/_auth/login');
  assert.strictEqual(r.headers['x-forwarded-host'].value, 'www.staging.example.com');
  // garbage policy -> redirect
  r = await gate.handler(ev('/about', {cookies:{...cookies,'CloudFront-Policy':{value:'!!!'}}}));
  assert.strictEqual(r.statusCode, 302);
  console.log('gate function tests passed');

  // ---- login lambda
  const key = crypto.generateKeyPairSync('rsa', {modulusLength: 2048});
  const pem = key.privateKey.export({type:'pkcs1', format:'pem'});
  const pub = key.publicKey;
  process.env.AUTH_PREFIX='/_auth/'; process.env.SESSION_SECONDS='3600'; process.env.SITE_HOST='www.staging.example.com';
  process.env.ALLOWED_HOSTS='www.staging.example.com,staging.example.com'; process.env.ALLOWED_EMAILS='Me@Example.com';
  process.env.COOKIE_DOMAIN='staging.example.com'; process.env.KEY_PAIR_ID='KPUB1'; process.env.CLIENT_ID='cid';
  process.env.COGNITO_DOMAIN='https://x-gate.auth.us-west-2.amazoncognito.com'; process.env.COGNITO_ISSUER='https://cognito-idp.us-west-2.amazonaws.com/us-west-2_abc';
  process.env.SIGNING_KEY_PARAM='/k'; process.env.CLIENT_SECRET_PARAM='/s';
  // stub SSM
  const ssmMod = require('@aws-sdk/client-ssm');
  ssmMod.SSMClient.prototype.send = async () => ({ Parameters: [{Name:'/k', Value: pem},{Name:'/s', Value:'secret'}] });
  const login = require('../lambda/login/index.js');
  const mk = (path, q={}, cookies=[], headers={}) => ({ rawPath: path, queryStringParameters: q, cookies, headers: {'x-forwarded-host':'www.staging.example.com', ...headers}, requestContext:{http:{method:'GET'}} });

  r = await login.handler(mk('/_auth/login', {next:'/cars/12?x=1'}));
  assert.strictEqual(r.statusCode, 302);
  const loc = new URL(r.headers.location);
  assert.strictEqual(loc.origin, 'https://x-gate.auth.us-west-2.amazoncognito.com');
  assert.strictEqual(loc.searchParams.get('redirect_uri'), 'https://www.staging.example.com/_auth/callback');
  const state = loc.searchParams.get('state');
  const stateCookie = r.cookies[0];
  assert(stateCookie.startsWith('__gate_state='+state+'.'));
  assert(stateCookie.includes('Path=/_auth/'));
  // spoofed host falls back to SITE_HOST
  r = await login.handler(mk('/_auth/login', {}, [], {'x-forwarded-host':'evil.com'}));
  assert.strictEqual(new URL(r.headers.location).searchParams.get('redirect_uri'), 'https://www.staging.example.com/_auth/callback');
  // open redirect attempts collapse to /
  for (const bad of ['//evil.com', 'https://evil.com', '/\\evil.com', '/_auth/login']) {
    r = await login.handler(mk('/_auth/login', {next: bad}));
    const sc = r.cookies[0].split(';')[0].split('=')[1];
    assert.strictEqual(Buffer.from(sc.split('.')[1], 'base64url').toString(), '/', 'bad next '+bad);
  }
  // callback: state mismatch
  r = await login.handler(mk('/_auth/callback', {code:'c', state:'wrong'}, [stateCookie.split(';')[0]]));
  assert.strictEqual(r.statusCode, 400);
  // callback: success with stubbed fetch
  const idPayload = Buffer.from(JSON.stringify({iss: process.env.COGNITO_ISSUER, aud:'cid', token_use:'id', exp: Math.floor(Date.now()/1000)+600, email:'me@example.com'})).toString('base64url');
  let capturedBody, capturedAuth;
  global.fetch = async (url, init) => { capturedBody = init.body; capturedAuth = init.headers.authorization; return { ok: true, status: 200, json: async () => ({ id_token: `h.${idPayload}.s` }) }; };
  r = await login.handler(mk('/_auth/callback', {code:'thecode', state}, [stateCookie.split(';')[0]]));
  assert.strictEqual(r.statusCode, 302, JSON.stringify(r));
  assert.strictEqual(r.headers.location, 'https://www.staging.example.com/cars/12?x=1');
  assert.strictEqual(capturedAuth, 'Basic ' + Buffer.from('cid:secret').toString('base64'));
  assert(capturedBody.includes('redirect_uri=https%3A%2F%2Fwww.staging.example.com%2F_auth%2Fcallback'));
  const set = Object.fromEntries(r.cookies.map(c => [c.split('=')[0], c]));
  assert(set['__gate_state'].includes('Max-Age=0'));
  for (const n of ['CloudFront-Policy','CloudFront-Signature','CloudFront-Key-Pair-Id']) {
    assert(set[n].includes('Domain=staging.example.com') && set[n].includes('HttpOnly') && set[n].includes('Max-Age=3600'), n);
  }
  // verify the signature the way CloudFront would
  const unsafe = (v) => v.replace(/-/g,'+').replace(/_/g,'=').replace(/~/g,'/');
  const policyB64 = set['CloudFront-Policy'].split(';')[0].split('=').slice(1).join('=');
  const policy = Buffer.from(unsafe(policyB64), 'base64').toString();
  const sig = Buffer.from(unsafe(set['CloudFront-Signature'].split(';')[0].slice('CloudFront-Signature='.length)), 'base64');
  assert(crypto.createVerify('RSA-SHA1').update(policy).verify(pub, sig), 'signature verifies');
  const pj = JSON.parse(policy);
  assert.strictEqual(pj.Statement[0].Resource, 'https://*staging.example.com/*');
  assert(!policy.includes(' '), 'policy compact');
  // gate function accepts the real cookie
  r = await gate.handler(ev('/about', {cookies: {'CloudFront-Policy':{value:policyB64},'CloudFront-Signature':{value:'x'},'CloudFront-Key-Pair-Id':{value:'KPUB1'}}}));
  assert.strictEqual(r.uri, '/about/index.html');
  // wrong email refused
  const badPayload = Buffer.from(JSON.stringify({iss: process.env.COGNITO_ISSUER, aud:'cid', token_use:'id', exp: Math.floor(Date.now()/1000)+600, email:'other@example.com'})).toString('base64url');
  global.fetch = async () => ({ ok: true, json: async () => ({ id_token: `h.${badPayload}.s` }) });
  r = await login.handler(mk('/_auth/login', {next:'/'}));
  const st2 = new URL(r.headers.location).searchParams.get('state'); const sc2 = r.cookies[0].split(';')[0];
  r = await login.handler(mk('/_auth/callback', {code:'c', state: st2}, [sc2]));
  assert.strictEqual(r.statusCode, 403);
  // logout + logged-out + 404 + POST
  r = await login.handler(mk('/_auth/logout')); assert.strictEqual(r.statusCode, 302); assert(r.headers.location.includes('/logout?client_id=cid&logout_uri=https%3A%2F%2Fwww.staging.example.com%2F_auth%2Flogged-out')); assert.strictEqual(r.cookies.length, 3);
  r = await login.handler(mk('/_auth/logged-out')); assert.strictEqual(r.statusCode, 200);
  r = await login.handler(mk('/_auth/nope')); assert.strictEqual(r.statusCode, 404);
  r = await login.handler({...mk('/_auth/login'), requestContext:{http:{method:'POST'}}}); assert.strictEqual(r.statusCode, 405);
  console.log('login lambda tests passed');

  // ---- authorizer
  // A throwaway key pair, signed the way the login Lambda signs, so the authorizer is exercised
  // against real RSA-SHA1 signatures rather than a stub.
  const akey = crypto.generateKeyPairSync('rsa', {modulusLength: 2048});
  const apriv = akey.privateKey.export({type:'pkcs1', format:'pem'});
  const apub = akey.publicKey.export({type:'spki', format:'pem'});
  const signPolicy = (exp, resource='https://*staging.example.com/*') => {
    const policy = JSON.stringify({Statement:[{Resource: resource, Condition:{DateLessThan:{'AWS:EpochTime': exp}}}]});
    return {
      policy: cfsafe(Buffer.from(policy, 'utf8')),
      signature: cfsafe(crypto.createSign('RSA-SHA1').update(policy, 'utf8').sign(apriv)),
    };
  };
  const gateCookies = (signed, kid='KPUB1') => [
    `CloudFront-Policy=${signed.policy}`,
    `CloudFront-Signature=${signed.signature}`,
    `CloudFront-Key-Pair-Id=${kid}`,
  ];
  const areq = (opts={}) => ({
    requestContext: {http: {method: opts.method || 'GET'}},
    headers: opts.headers || {},
    cookies: opts.cookies,
  });

  process.env.HEADER_NAME='x-origin-verify'; process.env.ORIGIN_VERIFY_PARAM='/o';
  process.env.KEY_PAIR_ID='KPUB1'; process.env.COOKIE_DOMAIN='staging.example.com';
  ssmMod.SSMClient.prototype.send = async () => ({ Parameter: { Value: 'S3CRET' } });
  // The signing public key reaches the function through the deployment package now, not through an
  // environment variable, so the tests build the package the way the module does.
  const auth = loadAuthorizer({ signingPublicKeyPem: apub });

  // CORS preflight is always allowed: it carries neither the header nor the cookies.
  assert.deepStrictEqual(await auth.handler(areq({method:'OPTIONS'})), {isAuthorized:true}, 'OPTIONS allowed');
  assert.deepStrictEqual(await auth.handler(areq({method:'options'})), {isAuthorized:true}, 'lowercase options allowed');

  // The origin verification header path is unchanged.
  assert.deepStrictEqual(await auth.handler(areq({headers:{'x-origin-verify':'S3CRET'}})), {isAuthorized:true}, 'header allowed');
  assert.deepStrictEqual(await auth.handler(areq({headers:{'X-Origin-Verify':'S3CRET'}})), {isAuthorized:true}, 'header case-insensitive');
  assert.deepStrictEqual(await auth.handler(areq({headers:{'x-origin-verify':'nope'}})), {isAuthorized:false}, 'wrong header denied');

  // A live, correctly signed cookie set, as event.cookies and as a raw cookie header.
  const live2 = Math.floor(Date.now()/1000)+3600;
  const good = signPolicy(live2);
  assert.deepStrictEqual(await auth.handler(areq({cookies: gateCookies(good)})), {isAuthorized:true}, 'valid cookies allowed');
  assert.deepStrictEqual(await auth.handler(areq({headers:{cookie: gateCookies(good).join('; ')}})), {isAuthorized:true}, 'valid cookie header allowed');
  // ... and alongside a wrong header value, which must not short-circuit the cookie check.
  assert.deepStrictEqual(await auth.handler(areq({headers:{'x-origin-verify':'nope'}, cookies: gateCookies(good)})), {isAuthorized:true}, 'cookies win over a bad header');

  // Expired policy.
  const stale = signPolicy(Math.floor(Date.now()/1000)-5);
  assert.deepStrictEqual(await auth.handler(areq({cookies: gateCookies(stale)})), {isAuthorized:false}, 'expired policy denied');

  // Wrong key pair id.
  assert.deepStrictEqual(await auth.handler(areq({cookies: gateCookies(good, 'SOMEONEELSE')})), {isAuthorized:false}, 'wrong key pair id denied');

  // Tampered signature, and a signature from a different key.
  const tampered = {...good, signature: good.signature.slice(0, -4) + 'AAAA'};
  assert.deepStrictEqual(await auth.handler(areq({cookies: gateCookies(tampered)})), {isAuthorized:false}, 'tampered signature denied');
  const other = crypto.generateKeyPairSync('rsa', {modulusLength: 2048});
  const otherPolicy = JSON.stringify({Statement:[{Resource:'https://*staging.example.com/*',Condition:{DateLessThan:{'AWS:EpochTime': live2}}}]});
  const forged = {policy: cfsafe(Buffer.from(otherPolicy)), signature: cfsafe(crypto.createSign('RSA-SHA1').update(otherPolicy).sign(other.privateKey.export({type:'pkcs1', format:'pem'})))};
  assert.deepStrictEqual(await auth.handler(areq({cookies: gateCookies(forged)})), {isAuthorized:false}, 'foreign key denied');

  // A policy signed for a different domain must not open this API.
  const wrongResource = signPolicy(live2, 'https://*staging.evil.com/*');
  assert.deepStrictEqual(await auth.handler(areq({cookies: gateCookies(wrongResource)})), {isAuthorized:false}, 'wrong resource denied');

  // Nothing at all, partial cookies, and garbage.
  assert.deepStrictEqual(await auth.handler(areq({})), {isAuthorized:false}, 'no credentials denied');
  assert.deepStrictEqual(await auth.handler(areq({cookies: gateCookies(good).slice(0, 2)})), {isAuthorized:false}, 'missing key pair id denied');
  assert.deepStrictEqual(await auth.handler(areq({cookies: ['CloudFront-Policy=!!!','CloudFront-Signature=!!!','CloudFront-Key-Pair-Id=KPUB1']})), {isAuthorized:false}, 'garbage cookies denied');

  // The cookies the login Lambda actually issued in the test above are accepted end to end.
  const auth2 = loadAuthorizer({ signingPublicKeyPem: pub.export({type:'spki', format:'pem'}) });
  assert.deepStrictEqual(await auth2.handler(areq({cookies: [
    `CloudFront-Policy=${policyB64}`,
    set['CloudFront-Signature'].split(';')[0],
    'CloudFront-Key-Pair-Id=KPUB1',
  ]})), {isAuthorized:true}, 'login lambda cookies accepted by the authorizer');

  // A package whose config file is missing fails closed rather than open: with no public key nothing
  // verifies, so a valid cookie set is refused instead of being waved through.
  const broken = loadAuthorizerWithoutConfig();
  assert.deepStrictEqual(await broken.handler(areq({cookies: gateCookies(good)})), {isAuthorized:false}, 'a package with no config file refuses signed cookies');
  // The origin verification header still works, because that credential does not depend on the file.
  assert.deepStrictEqual(await broken.handler(areq({headers:{'x-origin-verify':'S3CRET'}})), {isAuthorized:true}, 'the origin header is unaffected by a missing config file');

  console.log('authorizer tests passed');

  // ---- the identity access token half of the authorizer
  // Handed the gate helpers from above so its requests are ones that already pass the gate, which
  // is what lets every assertion there be about the token alone.
  await require('./identity_jwt.js')({
    gateCookies,
    signPolicy,
    publicPem: apub,
  });

  // ---- the rendered Lambda environment stays under the 4096 byte cap
  await require('./environment_size.js')();
})().catch(e => { console.error(e); process.exit(1); });
