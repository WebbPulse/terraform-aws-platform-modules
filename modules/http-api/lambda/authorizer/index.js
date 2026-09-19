'use strict';

const { readFileSync } = require('node:fs');
const path = require('node:path');

const {
  DEFAULT_JWKS_FETCH_TIMEOUT_MS,
  createIdentityVerifier,
} = require('./identity.js');

const CONFIG_PATH = path.join(__dirname, 'identity_jwt_config.json');

/**
 * Reads the packaged identity JWT configuration.
 * Returns empty values when the file is unreadable so the authorizer fails closed:
 * with no route keys nothing is enforced, and the module only ever attaches this
 * authorizer to routes it also packaged, so an unreadable config denies them.
 */
function loadConfig() {
  try {
    const parsed = JSON.parse(readFileSync(CONFIG_PATH, 'utf8'));
    return {
      routeKeys: Array.isArray(parsed.route_keys) ? parsed.route_keys : [],
      apiKeyPrefixes: Array.isArray(parsed.api_key_prefixes) ? parsed.api_key_prefixes : [],
      jwksFetchTimeoutMs: Number(parsed.jwks_fetch_timeout_ms) > 0 ? Number(parsed.jwks_fetch_timeout_ms) : DEFAULT_JWKS_FETCH_TIMEOUT_MS,
    };
  } catch (err) {
    console.error('identity_jwt_config.json could not be read, failing closed:', err.message);
    return {
      routeKeys: [],
      apiKeyPrefixes: [],
      jwksFetchTimeoutMs: DEFAULT_JWKS_FETCH_TIMEOUT_MS,
    };
  }
}

const CONFIG = loadConfig();

const ISSUER = process.env.IDENTITY_ISSUER || '';
const AUDIENCE = process.env.IDENTITY_AUDIENCE || '';

const ALLOW = { isAuthorized: true };
const DENY = { isAuthorized: false };

/**
 * The same verifier the staging access gate runs, built from the same source.
 * No fetchHeaders: without a gate in front the issuer's JWKS is reachable
 * directly, so the fetch goes out bare.
 */
const identity = createIdentityVerifier({
  issuer: ISSUER,
  audience: AUDIENCE,
  jwksUrl: process.env.IDENTITY_JWKS_URL || undefined,
  jwksTtlSeconds: process.env.IDENTITY_JWKS_TTL_SECONDS,
  jwksFetchTimeoutMs: CONFIG.jwksFetchTimeoutMs,
  jwksRetryBudgetMs: process.env.IDENTITY_JWKS_RETRY_BUDGET_MS,
  clockSkewSeconds: process.env.IDENTITY_CLOCK_SKEW_SECONDS,
  routeKeys: CONFIG.routeKeys,
  apiKeyPrefixes: CONFIG.apiKeyPrefixes,
});

/**
 * HTTP API REQUEST authorizer (payload 2.0) standing in for the native JWT
 * authorizer on the routes that require an identity access token.
 *
 * Admits preflights, then requires a bearer token: one matching a configured API
 * key prefix is passed through with no claims context for the function to verify
 * itself, and anything else is verified as an RS256 access token and its claims
 * handed on in the same shape the native authorizer produces. There is no gate
 * credential here, so the token is the only admission.
 */
exports.handler = async (event) => {
  const method = (((event.requestContext || {}).http || {}).method || '').toUpperCase();

  if (method === 'OPTIONS') {
    return ALLOW;
  }

  if (!identity.requiresIdentityJwt(event)) {
    console.warn('denied: this authorizer is attached to a route it was not configured to enforce');
    return DENY;
  }

  const token = identity.bearerToken(event);
  if (!token) {
    console.warn('denied: route requires an identity access token and no bearer token was presented');
    return DENY;
  }

  if (identity.isApiKeyBearer(token)) {
    return ALLOW;
  }

  const claims = await identity.verifyAccessToken(token);
  if (!claims) {
    return DENY;
  }

  return { isAuthorized: true, context: identity.claimsContext(claims) };
};

exports.resetJwksCache = identity.resetJwksCache;

/** Returns the sorted route keys the handler is enforcing. For the tests. */
exports.enforcedRouteKeys = identity.enforcedRouteKeys;

/** Returns the bearer token prefixes passed through on JWT routes. For the tests. */
exports.apiKeyPrefixes = identity.apiKeyPrefixes;
