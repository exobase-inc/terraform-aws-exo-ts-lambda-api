
output "url" {
  value = aws_apigatewayv2_stage.default.invoke_url
}

output "role_arn" {
  value = aws_iam_role.lambda_role.arn
}

output "role_name" {
  value = aws_iam_role.lambda_role.name
}