/**
 * Runs before the gate on non-API, non-auth requests. Return a response to end
 * the request early, or return the request to continue into the session check.
 */
function appHandler(event) {
  var request = event.request;
  var host = request.headers.host && request.headers.host.value;
  if (host === 'staging.example.com') {
    return {
      statusCode: 301,
      statusDescription: 'Moved Permanently',
      headers: { location: { value: 'https://www.staging.example.com' + request.uri } },
    };
  }
  return request;
}
