# Adoption from 1.x.
#
# In 1.x there was exactly one integration and one invoke permission, at the unkeyed addresses
# aws_apigatewayv2_integration.lambda and aws_lambda_permission.api. In 2.0 both are for_each over
# var.integrations. A moved block requires a constant key (Terraform rejects an expression there),
# so the module ships these two for the key "legacy" and 2.0 asks an adopting consumer to name its
# existing single backend "legacy". That is the whole cost of the upgrade: rename nothing in AWS,
# call one map key "legacy", and the plan is 2 to move, 0 to destroy.
#
# The routes need no moved block at all. In 1.x a route's address was
# aws_apigatewayv2_route.this["<route key>"] and in 2.0 it still is, because the for_each key is
# still the route key. A consumer that keeps its route keys keeps its route addresses.
#
# Both blocks are inert for a consumer that has no 1.x state at these addresses, and inert for a
# consumer whose integrations map has no "legacy" key, so they are safe to leave in place. They can
# be deleted in a later major once every consumer has applied once.

moved {
  from = aws_apigatewayv2_integration.lambda
  to   = aws_apigatewayv2_integration.this["legacy"]
}

moved {
  from = aws_lambda_permission.api
  to   = aws_lambda_permission.this["legacy"]
}
