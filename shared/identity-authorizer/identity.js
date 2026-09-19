'use strict';

/**
 * Identity access token verification shared by the staging-access-gate authorizer
 * and the http-api identity Lambda authorizer.
 *
 * Both modules package this file next to their own handler, so a token that one
 * admits the other admits too: the same RS256 verification, the same JWKS cache
 * and fetch timeout, the same API key prefix passthrough and the same claims
 * context shape. Nothing here knows about gate cookies or origin secrets.
 */

const { createPublicKey, verify: verifySignature } = require('node:crypto');

const DEFAULT_JWKS_FETCH_TIMEOUT_MS = 4000;
const DEFAULT_JWKS_TTL_SECONDS = 300;
const DEFAULT_CLOCK_SKEW_SECONDS = 60;
const DEFAULT_JWKS_RETRY_BUDGET_MS = 9000;

/** Returns the request path from either payload 2.0 shape. */
function requestPath(event) {
  return String(
    event.rawPath || ((event.requestContext || {}).http || {}).path || '',
  );
}

/** Case-insensitive header lookup against an already lowercased name. */
function header(event, name) {
  const headers = event.headers || {};
  for (const key of Object.keys(headers)) {
    if (key.toLowerCase() === name) {
      return headers[key];
    }
  }
  return undefined;
}

/** Extracts the bearer token from the Authorization header, or null. */
function bearerToken(event) {
  const value = header(event, 'authorization');
  if (!value) {
    return null;
  }
  const match = /^Bearer[ ]+(.+)$/i.exec(String(value).trim());
  return match ? match[1].trim() : null;
}

/** Decodes one base64url JWT segment into an object. */
function decodeSegment(segment) {
  return JSON.parse(Buffer.from(segment, 'base64url').toString('utf8'));
}

/**
 * Shapes verified claims into the authorizer context, mirroring the native JWT
 * authorizer. Every value is a string, since API Gateway rejects nested objects.
 */
function claimsContext(claims) {
  const stringified = {};
  for (const [key, value] of Object.entries(claims)) {
    stringified[key] = typeof value === 'string' ? value : JSON.stringify(value);
  }
  return {
    'jwt.claims': JSON.stringify(stringified),
    'jwt.claims.sub': stringified.sub || '',
    'jwt.claims.iss': stringified.iss || '',
    'jwt.claims.exp': stringified.exp || '',
  };
}

/** Normalises a configured string list, dropping blanks. */
function cleanList(values) {
  return (Array.isArray(values) ? values : [])
    .map((s) => String(s).trim())
    .filter(Boolean);
}

/**
 * Builds a verifier bound to one issuer, audience and key set.
 *
 * `options.fetchHeaders` is an optional async function returning headers to send
 * on the JWKS fetch. The gate uses it to present its origin verification header,
 * because in that topology the issuer sits behind the very gate this authorizer
 * enforces. On an API with no gate it is omitted and the fetch goes out bare.
 */
function createIdentityVerifier(options) {
  const issuer = String(options.issuer || '');
  const audience = String(options.audience || '');
  const jwksUrl = String(options.jwksUrl || (issuer ? `${issuer}/.well-known/jwks.json` : ''));

  const jwksTtlMs = Number(options.jwksTtlSeconds || DEFAULT_JWKS_TTL_SECONDS) * 1000;
  const jwksTimeoutMs = Number(options.jwksFetchTimeoutMs) > 0
    ? Number(options.jwksFetchTimeoutMs)
    : DEFAULT_JWKS_FETCH_TIMEOUT_MS;
  const jwksRetryBudgetMs = Number(options.jwksRetryBudgetMs || DEFAULT_JWKS_RETRY_BUDGET_MS);
  const clockSkewSeconds = Number(
    options.clockSkewSeconds === undefined ? DEFAULT_CLOCK_SKEW_SECONDS : options.clockSkewSeconds,
  );

  const routeKeys = new Set(cleanList(options.routeKeys));
  const apiKeyPrefixes = cleanList(options.apiKeyPrefixes);
  const anonymousPathPrefixes = cleanList(options.anonymousPathPrefixes);
  const fetchHeaders = typeof options.fetchHeaders === 'function' ? options.fetchHeaders : null;

  let jwksCache = { keys: null, fetchedAt: 0, inFlight: null };

  /** Clears the per-environment JWKS cache. Exported for the tests. */
  function resetJwksCache() {
    jwksCache = { keys: null, fetchedAt: 0, inFlight: null };
  }

  /**
   * Fetches the issuer's JWKS once, presenting any caller supplied headers so the
   * fetch survives a gate that guards the issuer's own API.
   */
  async function fetchJwksOnce() {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), jwksTimeoutMs);
    try {
      let headers = {};
      if (fetchHeaders) {
        try {
          headers = (await fetchHeaders()) || {};
        } catch (err) {
          console.warn('JWKS fetch headers unavailable:', err.message);
        }
      }
      const response = await fetch(jwksUrl, { signal: controller.signal, headers });
      if (!response.ok) {
        throw new Error(`JWKS fetch returned ${response.status}`);
      }
      const body = await response.json();
      const keys = Array.isArray(body && body.keys) ? body.keys : [];
      if (keys.length === 0) {
        throw new Error('JWKS has no keys');
      }
      return keys;
    } finally {
      clearTimeout(timer);
    }
  }

  /**
   * Fetches the JWKS, retrying once when the first attempt fails and the retry's
   * own timeout still fits the budget left inside this invocation. A cold identity
   * function is the common first failure, and it is warm by the second attempt.
   */
  async function fetchJwks() {
    const startedAt = Date.now();
    try {
      return await fetchJwksOnce();
    } catch (err) {
      const remaining = jwksRetryBudgetMs - (Date.now() - startedAt);
      if (remaining < jwksTimeoutMs) {
        throw err;
      }
      console.warn('JWKS fetch failed, retrying once:', err.message);
      return fetchJwksOnce();
    }
  }

  /**
   * Returns the cached key set, refetching past the TTL or when `force` is set.
   * A failed refresh falls back to the cached keys rather than refusing every request.
   */
  async function jwks(force) {
    const fresh = jwksCache.keys && Date.now() - jwksCache.fetchedAt < jwksTtlMs;
    if (fresh && !force) {
      return jwksCache.keys;
    }
    if (jwksCache.inFlight) {
      return jwksCache.inFlight;
    }

    jwksCache.inFlight = fetchJwks()
      .then((keys) => {
        jwksCache = { keys, fetchedAt: Date.now(), inFlight: null };
        return keys;
      })
      .catch((err) => {
        jwksCache.inFlight = null;
        if (jwksCache.keys) {
          console.warn('JWKS refresh failed, using the cached key set:', err.message);
          return jwksCache.keys;
        }
        throw err;
      });

    return jwksCache.inFlight;
  }

  /**
   * Resolves the JWK for a kid, refetching once on a miss so a key rotation takes
   * effect within one request. Returns null when the kid stays unknown.
   */
  async function keyFor(kid) {
    let keys = await jwks(false);
    let match = keys.find((k) => k.kid === kid);
    if (!match) {
      keys = await jwks(true);
      match = keys.find((k) => k.kid === kid);
    }
    if (!match) {
      return null;
    }
    if (match.kty !== 'RSA') {
      throw new Error(`JWKS key ${kid} is ${match.kty}, and only RSA is verifiable here`);
    }
    return createPublicKey({ key: match, format: 'jwk' });
  }

  /**
   * Verifies an RS256 access token against the issuer's JWKS and checks iss, aud,
   * exp and nbf. Returns the claims, or null with a logged reason.
   */
  async function verifyAccessToken(token) {
    const parts = String(token).split('.');
    if (parts.length !== 3) {
      console.warn('access token rejected: not three segments');
      return null;
    }

    let head;
    let claims;
    try {
      head = decodeSegment(parts[0]);
      claims = decodeSegment(parts[1]);
    } catch (err) {
      console.warn('access token rejected: undecodable header or payload');
      return null;
    }

    if (head.alg !== 'RS256') {
      console.warn(`access token rejected: alg is ${head.alg}, only RS256 is accepted`);
      return null;
    }
    if (!head.kid) {
      console.warn('access token rejected: no kid in the header');
      return null;
    }

    let key;
    try {
      key = await keyFor(head.kid);
    } catch (err) {
      console.warn('access token rejected: JWKS unavailable:', err.message);
      return null;
    }
    if (!key) {
      console.warn('access token rejected: kid is not in the JWKS, including after a refresh');
      return null;
    }

    const signed = Buffer.from(`${parts[0]}.${parts[1]}`, 'utf8');
    const signature = Buffer.from(parts[2], 'base64url');
    if (!verifySignature('RSA-SHA256', signed, key, signature)) {
      console.warn('access token rejected: signature does not verify');
      return null;
    }

    if (claims.iss !== issuer) {
      console.warn('access token rejected: wrong issuer');
      return null;
    }

    const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
    if (!audiences.includes(audience)) {
      console.warn('access token rejected: wrong audience');
      return null;
    }

    const now = Math.floor(Date.now() / 1000);
    if (typeof claims.exp !== 'number' || now >= claims.exp + clockSkewSeconds) {
      console.warn('access token rejected: expired or no exp');
      return null;
    }
    if (typeof claims.nbf === 'number' && now < claims.nbf - clockSkewSeconds) {
      console.warn('access token rejected: not yet valid');
      return null;
    }

    return claims;
  }

  /**
   * True when a bearer token is shaped like one of the configured API key prefixes.
   * The token itself is never logged.
   */
  function isApiKeyBearer(token) {
    if (apiKeyPrefixes.length === 0) {
      return false;
    }
    return apiKeyPrefixes.some((prefix) => String(token).startsWith(prefix));
  }

  /** True when this request's route key is one of the token-enforced routes. */
  function requiresIdentityJwt(event) {
    if (routeKeys.size === 0 || !issuer || !audience) {
      return false;
    }
    const routeKey = (event.routeKey || (event.requestContext || {}).routeKey || '').trim();
    return routeKeys.has(routeKey);
  }

  /** True when the request path matches a prefix admitted without any credential. */
  function isAnonymousPath(event) {
    if (anonymousPathPrefixes.length === 0) {
      return false;
    }
    const path = requestPath(event);
    if (!path) {
      return false;
    }
    return anonymousPathPrefixes.some((prefix) => path === prefix || path.startsWith(prefix));
  }

  return {
    anonymousPathPrefixes: () => [...anonymousPathPrefixes],
    apiKeyPrefixes: () => [...apiKeyPrefixes],
    bearerToken,
    claimsContext,
    enforcedRouteKeys: () => [...routeKeys].sort(),
    header,
    isAnonymousPath,
    isApiKeyBearer,
    requestPath,
    requiresIdentityJwt,
    resetJwksCache,
    verifyAccessToken,
  };
}

module.exports = {
  DEFAULT_JWKS_FETCH_TIMEOUT_MS,
  DEFAULT_JWKS_TTL_SECONDS,
  DEFAULT_CLOCK_SKEW_SECONDS,
  bearerToken,
  claimsContext,
  cleanList,
  createIdentityVerifier,
  header,
  requestPath,
};
