moved {
  from = aws_apigatewayv2_integration.lambda
  to   = aws_apigatewayv2_integration.this["legacy"]
}

moved {
  from = aws_lambda_permission.api
  to   = aws_lambda_permission.this["legacy"]
}
