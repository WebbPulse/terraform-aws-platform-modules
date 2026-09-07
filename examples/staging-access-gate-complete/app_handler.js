// Runs before the gate on every non-API, non-auth request. Return a response to end the request
// early (redirects), or return event.request, rewritten or not, to continue into the gate check.
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
