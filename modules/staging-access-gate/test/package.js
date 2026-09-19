/**
 * Builds the authorizer deployment package under test/.build/ the way the
 * Terraform module builds it, so the tests load the handler from a real package.
 */

const fs = require('node:fs');
const path = require('node:path');

const SOURCE = path.join(__dirname, '..', 'lambda', 'authorizer', 'index.js');
const ROOT = path.join(__dirname, '.build');

let counter = 0;

/** Renders identity_jwt_config.json exactly as locals.tf does, with the route keys sorted. */
function renderConfig({
  routeKeys = [],
  signingPublicKeyPem = '',
  anonymousPathPrefixes = [],
  apiKeyPrefixes = [],
} = {}) {
  return JSON.stringify({
    route_keys: [...routeKeys].sort(),
    signing_public_key_pem: signingPublicKeyPem,
    anonymous_path_prefixes: anonymousPathPrefixes,
    api_key_prefixes: apiKeyPrefixes,
  });
}

/**
 * Writes a fresh package and requires the handler from it. Each call gets its own
 * directory, so packages with different configs load side by side.
 */
function loadAuthorizer(config) {
  counter += 1;
  const dir = path.join(ROOT, `authorizer-${counter}`);
  fs.mkdirSync(dir, { recursive: true });
  fs.copyFileSync(SOURCE, path.join(dir, 'index.js'));
  fs.writeFileSync(path.join(dir, 'identity_jwt_config.json'), renderConfig(config));
  const entry = path.join(dir, 'index.js');
  delete require.cache[entry];
  return require(entry);
}

/** Writes a package whose config predates a key, for the old-package assertions. */
function loadAuthorizerWithRawConfig(config) {
  counter += 1;
  const dir = path.join(ROOT, `authorizer-${counter}`);
  fs.mkdirSync(dir, { recursive: true });
  fs.copyFileSync(SOURCE, path.join(dir, 'index.js'));
  fs.writeFileSync(path.join(dir, 'identity_jwt_config.json'), JSON.stringify(config));
  const entry = path.join(dir, 'index.js');
  delete require.cache[entry];
  return require(entry);
}

/** Builds a package with the config file missing, for the fail-closed assertion. */
function loadAuthorizerWithoutConfig() {
  counter += 1;
  const dir = path.join(ROOT, `authorizer-${counter}`);
  fs.mkdirSync(dir, { recursive: true });
  fs.copyFileSync(SOURCE, path.join(dir, 'index.js'));
  const entry = path.join(dir, 'index.js');
  delete require.cache[entry];
  return require(entry);
}

module.exports = { loadAuthorizer, loadAuthorizerWithoutConfig, loadAuthorizerWithRawConfig, renderConfig };
