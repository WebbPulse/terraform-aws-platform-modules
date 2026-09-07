'use strict';

// HTTP API REQUEST authorizer (payload 2.0, simple responses). The authorizer has no identity
// sources, so API Gateway invokes it on every request to a route that uses it and never caches the
// answer; the SSM read below still happens once per cold start and is reused after that.
//
// A request is authorized when any of these holds, checked in order:
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
// Cookie values are never logged.

const { SSMClient, GetParameterCommand } = require('@aws-sdk/client-ssm');
const { timingSafeEqual, createVerify } = require('node:crypto');

const ssm = new SSMClient({});
const HEADER_NAME = (process.env.HEADER_NAME || 'x-origin-verify').toLowerCase();
const KEY_PAIR_ID = process.env.KEY_PAIR_ID || '';
const PUBLIC_KEY_PEM = process.env.SIGNING_PUBLIC_KEY_PEM || '';
const COOKIE_DOMAIN = process.env.COOKIE_DOMAIN || '';
const EXPECTED_RESOURCE = `https://*${COOKIE_DOMAIN}/*`;

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
// the public half of the CloudFront key pair. The PEM is public, so it lives in an environment
// variable rather than SSM.
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

exports.handler = async (event) => {
  const method = (((event.requestContext || {}).http || {}).method || '').toUpperCase();

  // A CORS preflight is sent without credentials, so it can never carry the header or the cookies.
  // Letting it through lets the application's own CORS middleware answer it.
  if (method === 'OPTIONS') {
    return ALLOW;
  }

  const presented = header(event, HEADER_NAME);
  if (presented !== undefined) {
    const want = await expected();
    if (equal(presented, want)) {
      return ALLOW;
    }
  }

  return signedCookiesValid(event) ? ALLOW : DENY;
};
