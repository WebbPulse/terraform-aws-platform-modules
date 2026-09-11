// Builds the authorizer deployment package the way the Terraform module builds it, so the unit
// tests load the handler out of a real package rather than out of the module source directory.
//
// The module's archive_file has two source blocks: lambda/authorizer/index.js verbatim, and
// identity_jwt_config.json rendered from the module's inputs. index.js reads that JSON next to
// itself at import time, so a test that required ../lambda/authorizer/index.js directly would be
// testing a package that can never be deployed: the config file is not on disk in the source tree
// and must not be, because Terraform renders it per consumer.
//
// Everything lands under test/.build/, which .gitignore already covers.

const fs = require('node:fs');
const path = require('node:path');

const SOURCE = path.join(__dirname, '..', 'lambda', 'authorizer', 'index.js');
const ROOT = path.join(__dirname, '.build');

let counter = 0;

// Renders identity_jwt_config.json exactly as locals.tf does: the same two keys, the route key list
// sorted, and JSON.stringify standing in for jsonencode.
function renderConfig({ routeKeys = [], signingPublicKeyPem = '', anonymousPathPrefixes = [] } = {}) {
  return JSON.stringify({
    route_keys: [...routeKeys].sort(),
    signing_public_key_pem: signingPublicKeyPem,
    anonymous_path_prefixes: anonymousPathPrefixes,
  });
}

// Writes a fresh package and returns the freshly required handler module. Each call gets its own
// directory and its own require path, so two packages with different route key lists can be loaded
// side by side without fighting over the module cache.
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

// A package with the config file deliberately missing, for the fail-closed assertion.
function loadAuthorizerWithoutConfig() {
  counter += 1;
  const dir = path.join(ROOT, `authorizer-${counter}`);
  fs.mkdirSync(dir, { recursive: true });
  fs.copyFileSync(SOURCE, path.join(dir, 'index.js'));
  const entry = path.join(dir, 'index.js');
  delete require.cache[entry];
  return require(entry);
}

module.exports = { loadAuthorizer, loadAuthorizerWithoutConfig, renderConfig };
