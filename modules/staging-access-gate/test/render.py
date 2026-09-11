#!/usr/bin/env python3
"""Render gate.js.tftpl the way Terraform would, with a sample appHandler, for the local tests."""
import pathlib
root = pathlib.Path(__file__).resolve().parent.parent
t = (root / 'cloudfront_functions' / 'gate.js.tftpl').read_text()
app = '''function appHandler(event) {
  var request = event.request;
  var host = request.headers.host && request.headers.host.value;
  if (host === 'staging.example.com') {
    return { statusCode: 301, statusDescription: 'Moved Permanently', headers: { location: { value: 'https://www.staging.example.com' + request.uri } } };
  }
  if (request.uri !== '/' && request.uri.lastIndexOf('.') < request.uri.lastIndexOf('/')) { request.uri = request.uri + '/index.html'; }
  return request;
}'''
t = t.replace('${app_handler}', app).replace('${auth_prefix}', '/_auth/').replace('${api_prefix}', '/api/')
(root / 'test' / 'gate.rendered.js').write_text(t + '\nmodule.exports = { handler: handler, decodePolicy: decodePolicy };\n')
print('rendered', len(t), 'bytes')
