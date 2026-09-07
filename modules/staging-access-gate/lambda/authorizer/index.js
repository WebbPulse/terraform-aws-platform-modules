'use strict';

// HTTP API REQUEST authorizer (payload 2.0, simple responses). API Gateway only invokes this when
// the identity-source header is present, and caches the answer per header value for the TTL set on
// the authorizer, so the SSM read below happens once per cold start and rarely after that.

const { SSMClient, GetParameterCommand } = require('@aws-sdk/client-ssm');
const { timingSafeEqual } = require('node:crypto');

const ssm = new SSMClient({});
const HEADER_NAME = (process.env.HEADER_NAME || 'x-origin-verify').toLowerCase();

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

exports.handler = async (event) => {
  const headers = event.headers || {};
  let presented;
  for (const key of Object.keys(headers)) {
    if (key.toLowerCase() === HEADER_NAME) {
      presented = headers[key];
      break;
    }
  }
  if (presented === undefined) {
    return { isAuthorized: false };
  }
  const want = await expected();
  return { isAuthorized: equal(presented, want) };
};
