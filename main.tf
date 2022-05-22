
##
## DATA
##

data "aws_caller_identity" "current" {}

# data "aws_acm_certificate" "wildcard_domain" {
#   domain   = "*.lunecard.com"
#   statuses = ["ISSUED"]
# }

# data "aws_route53_zone" "main" {
#   name         = "lunecard.com."
#   private_zone = false
# }


##
## LOCALS
##
locals {
  source_dir  = "${path.module}/source" // really "${path.cwd}/source"
  dist_dir    = "${local.source_dir}/build"
  functions   = jsondecode(file("${local.source_dir}/.manifest.json")).functions
  envvars     = jsondecode(var.envvars)
  context     = jsondecode(var.exo_context)
  service_key = join("-", split(" ", lower(replace(local.context.unit.name, "[^\\w\\d]|_", ""))))
}


##
## API GATEWAY
##

resource "aws_apigatewayv2_api" "api" {
  name          = "${local.service_key}-api"
  description   = "Gateway proxying requests to lambdas for ${local.service_key}"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
}

# resource "aws_apigatewayv2_domain_name" "main" {
#   domain_name = local.domain
#   domain_name_configuration {
#     certificate_arn = data.aws_acm_certificate.wildcard_domain.arn
#     endpoint_type   = "REGIONAL"
#     security_policy = "TLS_1_2"
#   }
# }

# resource "aws_apigatewayv2_api_mapping" "main" {
#   # count = var.cloudflare ? 1 : 0
#   api_id      = aws_apigatewayv2_api.api.id
#   domain_name = aws_apigatewayv2_domain_name.main.id
#   stage       = aws_apigatewayv2_stage.default.id
# }

# resource "aws_route53_record" "main" {
#   name    = aws_apigatewayv2_domain_name.main.domain_name
#   type    = "A"
#   zone_id = data.aws_route53_zone.main.zone_id

#   alias {
#     name                   = aws_apigatewayv2_domain_name.main.domain_name_configuration[0].target_domain_name
#     zone_id                = aws_apigatewayv2_domain_name.main.domain_name_configuration[0].hosted_zone_id
#     evaluate_target_health = false
#   }
# }


##
## S3 ARCHIVE
##

resource "aws_s3_bucket" "zips" {
  bucket = "${local.service_key}-zip-archives"
}

resource "aws_s3_bucket_acl" "zips" {
  bucket = aws_s3_bucket.zips.id
  acl    = "private"
}

resource "aws_s3_object" "zips" {
  for_each = { for func in local.functions : "${func.module}_${func.function}" => func }
  bucket = aws_s3_bucket.zips.bucket
  key    = "${each.value.module}_${each.value.function}.zip"
  source = "${local.dist_dir}/modules/${each.value.module}/${each.value.function}.zip"
  etag   = filemd5("${local.dist_dir}/modules/${each.value.module}/${each.value.function}.zip")
}


##
## LAMBDAS
##

module "lambda" {
  source = "git::https://git@github.com/terraform-aws-modules/terraform-aws-lambda.git?ref=v3.2.0"

  for_each = { for func in local.functions : "${func.module}_${func.function}" => func }

  function_name  = "${local.service_key}-api-${each.value.module}-${each.value.function}"
  handler        = "${each.value.function}.default"
  timeout        = var.timeout
  memory_size    = var.memory
  
  s3_existing_package = {
    bucket = aws_s3_bucket.zips.bucket
    key    = aws_s3_object.zips[each.key].key
  }

  tracing_mode   = "Active"
  lambda_role    = aws_iam_role.lambda_role.arn
  create_role    = false
  create_package = false
  runtime        = "nodejs14.x"
  # environment_variables = merge(local.envvars, {
  #   EXO_MODULE   = each.value.module
  #   EXO_FUNCTION = each.value.function
  # })
  environment_variables = merge([for ev in local.envvars : {
    "${ev.name}": ev.value
  }], {
    EXO_MODULE   = each.value.module
    EXO_FUNCTION = each.value.function
  })

  depends_on = [
    aws_s3_object.zips
  ]
}


##
## API GATEWAY ROUTES
##

resource "aws_apigatewayv2_route" "main" {

  for_each = { for func in local.functions : "${func.module}_${func.function}" => func }

  api_id    = aws_apigatewayv2_api.api.id
  route_key = "ANY /${each.value.module}/${each.value.function}"
  target    = "integrations/${aws_apigatewayv2_integration.main[each.key].id}"
}

resource "aws_apigatewayv2_integration" "main" {

  for_each = { for func in local.functions : "${func.module}_${func.function}" => func }

  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_method     = "ANY"
  integration_uri        = module.lambda[each.key].lambda_function_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 20000

  # Due to open issue - https://github.com/terraform-providers/terraform-provider-aws/issues/11148#issuecomment-619160589
  # Bug in terraform-aws-provider with perpetual diff
  lifecycle {
    ignore_changes = [passthrough_behavior]
  }

  depends_on = [
    module.lambda
  ]
}

resource "aws_lambda_permission" "apigw" {

  for_each = { for func in local.functions : "${func.module}_${func.function}" => func }

  statement_id = "AllowAPIGatewayInvoke"
  action       = "lambda:InvokeFunction"
  principal    = "apigateway.amazonaws.com"

  # The "/*/*" portion grants access from any method on any resource
  # within the API Gateway REST API.
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*" // TODO: Be more specific
  function_name = module.lambda[each.key].lambda_function_name

  depends_on = [
    module.lambda
  ]
}


##
## LAMBDA IAM
##

data "aws_iam_policy_document" "lambda_policy_doc" {

  statement {
    effect    = "Allow"
    resources = ["*"]
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
  }

  statement {
    effect    = "Allow"
    resources = ["*"]
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords"
    ]
  }

  statement {
    effect = "Allow"
    resources = [
      "arn:aws:lambda:${var.region}:${data.aws_caller_identity.current.account_id}:function:*"
    ]
    actions = [
      "lambda:InvokeFunction"
    ]
  }

  statement {
    effect = "Allow"
    resources = [
      "arn:aws:dynamodb:${var.region}:${data.aws_caller_identity.current.account_id}:table/*"
    ]
    actions = [
      "dynamodb:BatchGetItem",
      "dynamodb:GetItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:BatchWriteItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:GetRecords"
    ]
  }

}

data "aws_iam_policy_document" "policy" {
  statement {
    sid     = ""
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "frontend_lambda_role_policy" {
  name   = "${local.service_key}-api-lambda-policy"
  role   = aws_iam_role.lambda_role.id
  policy = data.aws_iam_policy_document.lambda_policy_doc.json
}

resource "aws_iam_role" "lambda_role" {
  name                  = "${local.service_key}-api-lambda-role"
  assume_role_policy    = data.aws_iam_policy_document.policy.json
  force_detach_policies = true
}
