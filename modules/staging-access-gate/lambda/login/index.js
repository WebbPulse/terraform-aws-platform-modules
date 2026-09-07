'use strict';

// Access gate login handler, reached through a CloudFront ordered behavior on <AUTH_PREFIX>* whose
// origin is this function's URL (IAM auth, signed by a CloudFront origin access control).
//
//   GET <AUTH_PREFIX>login?next=/path   -> remember next in a short-lived state cookie, send the
//                                          browser to the Cognito hosted UI
//   GET <AUTH_PREFIX>callback?code&state -> check state, exchange the code for tokens using the
//                                          client secret, confirm the email is allowed, then set
//                                          CloudFront signed cookies and go to next
//   GET <AUTH_PREFIX>logout             -> clear the cookies, sign out of Cognito
//   GET <AUTH_PREFIX>logged-out         -> a plain page saying so
//
// The signed cookies use a CloudFront custom policy that covers https://*<COOKIE_DOMAIN>/* and
// expires after SESSION_SECONDS; CloudFront verifies them on every protected behavior via the key
// group, so nothing here has to be consulted again until the session lapses.

const crypto = require('node:crypto');
const { SSMClient, GetParametersCommand } = require('@aws-sdk/client-ssm');

const env = process.env;
const AUTH_PREFIX = env.AUTH_PREFIX || '/_auth/';
const SESSION_SECONDS = parseInt(env.SESSION_SECONDS || '43200', 10);
const ALLOWED_HOSTS = new Set((env.ALLOWED_HOSTS || env.SITE_HOST).split(',').map((h) => h.trim().toLowerCase()).filter(Boolean));
const ALLOWED_EMAILS = new Set((env.ALLOWED_EMAILS || '').split(',').map((e) => e.trim().toLowerCase()).filter(Boolean));
const STATE_COOKIE = '__gate_state';
const SESSION_COOKIES = ['CloudFront-Policy', 'CloudFront-Signature', 'CloudFront-Key-Pair-Id'];

const ssm = new SSMClient({});
let secretsPromise;

function secrets() {
  if (!secretsPromise) {
    secretsPromise = ssm
      .send(new GetParametersCommand({ Names: [env.SIGNING_KEY_PARAM, env.CLIENT_SECRET_PARAM], WithDecryption: true }))
      .then((r) => {
        const byName = Object.fromEntries((r.Parameters || []).map((p) => [p.Name, p.Value]));
        const signingKey = byName[env.SIGNING_KEY_PARAM];
        const clientSecret = byName[env.CLIENT_SECRET_PARAM];
        if (!signingKey || !clientSecret) {
          throw new Error(`missing SSM parameters: ${(r.InvalidParameters || []).join(', ')}`);
        }
        return { signingKey, clientSecret };
      })
      .catch((err) => {
        secretsPromise = undefined;
        throw err;
      });
  }
  return secretsPromise;
}

// ---------------------------------------------------------------------------------------------
// Small helpers

function cloudFrontSafeBase64(buf) {
  return buf.toString('base64').replace(/\+/g, '-').replace(/=/g, '_').replace(/\//g, '~');
}

function b64url(str) {
  return Buffer.from(str, 'utf8').toString('base64url');
}

function fromB64url(str) {
  return Buffer.from(str, 'base64url').toString('utf8');
}

function parseCookies(event) {
  const out = {};
  for (const raw of event.cookies || []) {
    const i = raw.indexOf('=');
    if (i > 0) {
      out[raw.slice(0, i).trim()] = raw.slice(i + 1).trim();
    }
  }
  return out;
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

// The host the viewer used. CloudFront rewrites Host to the function URL, so the gate function
// copies the viewer's Host into x-forwarded-host; anything not on the allow list falls back to
// SITE_HOST so a spoofed header cannot steer the redirect_uri or the post-login redirect.
function viewerHost(event) {
  const forwarded = (header(event, 'x-forwarded-host') || '').toLowerCase().split(':')[0];
  return ALLOWED_HOSTS.has(forwarded) ? forwarded : env.SITE_HOST;
}

// Only same-site, absolute-path targets. Anything else (open redirects, protocol-relative URLs,
// the auth prefix itself) collapses to the site root.
function safeNext(value) {
  if (typeof value !== 'string' || value === '') {
    return '/';
  }
  if (!value.startsWith('/') || value.startsWith('//') || value.startsWith('/\\') || value.includes('\\')) {
    return '/';
  }
  if (value.startsWith(AUTH_PREFIX)) {
    return '/';
  }
  return value;
}

function cookie(name, value, attrs) {
  const parts = [`${name}=${value}`, 'Path=' + (attrs.path || '/'), 'Secure', 'HttpOnly', 'SameSite=Lax'];
  if (attrs.domain) {
    parts.push(`Domain=${attrs.domain}`);
  }
  if (attrs.maxAge !== undefined) {
    parts.push(`Max-Age=${attrs.maxAge}`);
  }
  return parts.join('; ');
}

function clearedSessionCookies() {
  return SESSION_COOKIES.map((name) => cookie(name, '', { domain: env.COOKIE_DOMAIN, maxAge: 0 }));
}

function respond(statusCode, body, extra = {}) {
  return {
    statusCode,
    headers: {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
      'x-content-type-options': 'nosniff',
      'referrer-policy': 'no-referrer',
      ...(extra.headers || {}),
    },
    cookies: extra.cookies || [],
    body: body || '',
  };
}

function redirect(location, cookies) {
  return respond(302, '', { headers: { location }, cookies });
}

function page(title, message) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${title}</title><style>body{font:16px/1.5 system-ui,sans-serif;max-width:32rem;margin:6rem auto;padding:0 1rem;color:#222}h1{font-size:1.4rem}a{color:#0a58ca}</style></head><body><h1>${title}</h1><p>${message}</p></body></html>`;
}

// ---------------------------------------------------------------------------------------------
// CloudFront signed cookies

function signedCookies(signingKey) {
  const expires = Math.floor(Date.now() / 1000) + SESSION_SECONDS;
  const policy = JSON.stringify({
    Statement: [
      {
        Resource: `https://*${env.COOKIE_DOMAIN}/*`,
        Condition: { DateLessThan: { 'AWS:EpochTime': expires } },
      },
    ],
  });
  const signature = crypto.createSign('RSA-SHA1').update(policy, 'utf8').sign(signingKey);
  const attrs = { domain: env.COOKIE_DOMAIN, maxAge: SESSION_SECONDS };
  return [
    cookie('CloudFront-Policy', cloudFrontSafeBase64(Buffer.from(policy, 'utf8')), attrs),
    cookie('CloudFront-Signature', cloudFrontSafeBase64(signature), attrs),
    cookie('CloudFront-Key-Pair-Id', env.KEY_PAIR_ID, attrs),
  ];
}

// ---------------------------------------------------------------------------------------------
// Routes

function login(event) {
  const host = viewerHost(event);
  const next = safeNext((event.queryStringParameters || {}).next);
  const state = crypto.randomBytes(24).toString('base64url');
  const redirectUri = `https://${host}${AUTH_PREFIX}callback`;

  const authorize = new URL(`${env.COGNITO_DOMAIN}/oauth2/authorize`);
  authorize.searchParams.set('client_id', env.CLIENT_ID);
  authorize.searchParams.set('response_type', 'code');
  authorize.searchParams.set('scope', 'openid email');
  authorize.searchParams.set('redirect_uri', redirectUri);
  authorize.searchParams.set('state', state);

  const stateCookie = cookie(STATE_COOKIE, `${state}.${b64url(next)}`, { path: AUTH_PREFIX, maxAge: 600 });
  return redirect(authorize.toString(), [stateCookie]);
}

function decodeJwtPayload(token) {
  const parts = String(token).split('.');
  if (parts.length !== 3) {
    throw new Error('id_token is not a JWT');
  }
  return JSON.parse(fromB64url(parts[1]));
}

async function callback(event) {
  const host = viewerHost(event);
  const query = event.queryStringParameters || {};
  const cookies = parseCookies(event);
  const clearState = cookie(STATE_COOKIE, '', { path: AUTH_PREFIX, maxAge: 0 });

  if (query.error) {
    return respond(400, page('Sign-in failed', `Cognito reported: ${escapeHtml(query.error_description || query.error)}. <a href="${AUTH_PREFIX}login">Try again</a>.`), { cookies: [clearState] });
  }

  const stored = cookies[STATE_COOKIE] || '';
  const dot = stored.indexOf('.');
  const expectedState = dot > 0 ? stored.slice(0, dot) : '';
  const next = dot > 0 ? safeNext(fromB64url(stored.slice(dot + 1))) : '/';

  if (!query.code || !query.state || !expectedState || !timingSafeEqualStrings(query.state, expectedState)) {
    return respond(400, page('Sign-in expired', `The sign-in attempt did not match this browser session. <a href="${AUTH_PREFIX}login">Start again</a>.`), { cookies: [clearState] });
  }

  const { signingKey, clientSecret } = await secrets();
  const basic = Buffer.from(`${env.CLIENT_ID}:${clientSecret}`, 'utf8').toString('base64');
  const form = new URLSearchParams({
    grant_type: 'authorization_code',
    client_id: env.CLIENT_ID,
    code: query.code,
    redirect_uri: `https://${host}${AUTH_PREFIX}callback`,
  });

  const tokenResponse = await fetch(`${env.COGNITO_DOMAIN}/oauth2/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded', authorization: `Basic ${basic}` },
    body: form.toString(),
  });

  if (!tokenResponse.ok) {
    const text = await tokenResponse.text();
    console.error('token exchange failed', tokenResponse.status, text.slice(0, 500));
    return respond(400, page('Sign-in failed', `The authorization code could not be exchanged. <a href="${AUTH_PREFIX}login">Try again</a>.`), { cookies: [clearState] });
  }

  const tokens = await tokenResponse.json();
  const claims = decodeJwtPayload(tokens.id_token);
  const now = Math.floor(Date.now() / 1000);

  // The token came straight from Cognito's token endpoint over TLS in exchange for the client
  // secret, so its signature has not been forged in transit; the claims are still checked so a
  // misconfigured client or pool cannot let the wrong audience through.
  if (claims.iss !== env.COGNITO_ISSUER || claims.aud !== env.CLIENT_ID || claims.token_use !== 'id' || !(claims.exp > now)) {
    console.error('rejected id token claims', { iss: claims.iss, aud: claims.aud, token_use: claims.token_use });
    return respond(403, page('Sign-in refused', 'The identity token did not belong to this site.'), { cookies: [clearState] });
  }

  const email = String(claims.email || '').toLowerCase();
  if (ALLOWED_EMAILS.size > 0 && !ALLOWED_EMAILS.has(email)) {
    console.warn('email not on the allow list', email);
    return respond(403, page('Not allowed', `${escapeHtml(email)} is not on the access list for this environment.`), { cookies: [clearState] });
  }

  console.log('session issued', { email, host, next });
  return redirect(`https://${host}${next}`, [clearState, ...signedCookies(signingKey)]);
}

function logout(event) {
  const host = viewerHost(event);
  const url = new URL(`${env.COGNITO_DOMAIN}/logout`);
  url.searchParams.set('client_id', env.CLIENT_ID);
  url.searchParams.set('logout_uri', `https://${host}${AUTH_PREFIX}logged-out`);
  return redirect(url.toString(), clearedSessionCookies());
}

function loggedOut() {
  return respond(200, page('Signed out', `Your staging session has ended. <a href="/">Sign in again</a>.`), { cookies: clearedSessionCookies() });
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
}

function timingSafeEqualStrings(a, b) {
  const ab = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  return ab.length === bb.length && crypto.timingSafeEqual(ab, bb);
}

exports.handler = async (event) => {
  const method = ((event.requestContext || {}).http || {}).method || 'GET';
  const path = event.rawPath || '/';

  if (method !== 'GET' && method !== 'HEAD') {
    return respond(405, page('Method not allowed', ''), { headers: { allow: 'GET, HEAD' } });
  }

  try {
    switch (path) {
      case `${AUTH_PREFIX}login`:
        return login(event);
      case `${AUTH_PREFIX}callback`:
        return await callback(event);
      case `${AUTH_PREFIX}logout`:
        return logout(event);
      case `${AUTH_PREFIX}logged-out`:
        return loggedOut();
      default:
        return respond(404, page('Not found', ''));
    }
  } catch (err) {
    console.error('access gate error', err);
    return respond(500, page('Something went wrong', `The sign-in service hit an error. <a href="${AUTH_PREFIX}login">Try again</a>.`));
  }
};
