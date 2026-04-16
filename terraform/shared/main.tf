data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  project_slug = replace(replace(lower(var.project_name), "/[^a-z0-9-]/", "-"), "/-+/", "-")

  common_tags = merge(
    {
      Project   = var.project_name
      ManagedBy = "Terraform"
      Security  = "Baseline"
      Scope     = "shared"
    },
    var.tags
  )

  default_environments = toset(["dev", "staging", "prod"])
  environments         = var.demo_mode ? var.active_environments : local.default_environments
}

resource "aws_sns_topic" "security_alerts" {
  name              = "${local.project_slug}-security-alerts"
  kms_master_key_id = var.use_customer_managed_kms ? aws_kms_key.cloudtrail[0].arn : null

  tags = local.common_tags
}

resource "aws_sns_topic_policy" "security_alerts" {
  arn = aws_sns_topic.security_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudTrailPublish"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.security_alerts.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:aws:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/${local.project_slug}-trail"
          }
        }
      }
    ]
  })
}

resource "aws_sns_topic_subscription" "security_email" {
  count     = var.enable_security_email_subscription ? 1 : 0
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = var.admin_email
}

resource "aws_kms_key" "cloudtrail" {
  count                   = var.use_customer_managed_kms ? 1 : 0
  description             = "KMS key for ${var.project_name} CloudTrail and central logs"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAccountRootAdministration"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudTrailEncrypt"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowSNSServiceUseOfKey"
        Effect = "Allow"
        Principal = {
          Service = "sns.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:aws:sns:*:${data.aws_caller_identity.current.account_id}:${local.project_slug}-security-alerts"
          }
        }
      },
      {
        Sid    = "AllowCloudTrailToUseSNSKmsKey"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:aws:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/${local.project_slug}-trail"
          }
        }
      },
      {
        Sid    = "AllowCloudWatchLogsEncrypt"
        Effect = "Allow"
        Principal = {
          Service = "logs.${var.aws_region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*"
        ]
        Resource = "*"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_kms_alias" "cloudtrail" {
  count         = var.use_customer_managed_kms ? 1 : 0
  name          = "alias/${local.project_slug}-cloudtrail"
  target_key_id = aws_kms_key.cloudtrail[0].key_id
}

resource "aws_s3_bucket" "security_logs" {
  bucket        = "${local.project_slug}-security-logs-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.name}"
  force_destroy = true

  tags = merge(local.common_tags, { DataClass = "audit" })
}

resource "aws_s3_bucket_versioning" "security_logs" {
  bucket = aws_s3_bucket.security_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_logging" "security_logs" {
  bucket        = aws_s3_bucket.security_logs.id
  target_bucket = aws_s3_bucket.security_logs.id
  target_prefix = "access-logs/"
}

resource "aws_s3_bucket_lifecycle_configuration" "security_logs" {
  bucket = aws_s3_bucket.security_logs.id

  rule {
    id     = "expire-audit-objects"
    status = "Enabled"

    filter {}

    expiration {
      days = 365
    }
  }
}

resource "aws_s3_bucket_public_access_block" "security_logs" {
  bucket = aws_s3_bucket.security_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "security_logs" {
  bucket = aws_s3_bucket.security_logs.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = var.use_customer_managed_kms ? aws_kms_key.cloudtrail[0].arn : null
      sse_algorithm     = var.use_customer_managed_kms ? "aws:kms" : "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_policy" "security_logs" {
  bucket = aws_s3_bucket.security_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.security_logs.arn
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.security_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.security_logs.arn,
          "${aws_s3_bucket.security_logs.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "cloudtrail" {
  count             = var.enable_cloudtrail ? 1 : 0
  name              = "/aws/cloudtrail/${local.project_slug}"
  retention_in_days = 365
  kms_key_id        = var.use_customer_managed_kms ? aws_kms_key.cloudtrail[0].arn : null

  tags = local.common_tags
}

resource "aws_iam_role" "cloudtrail_to_cw" {
  count = var.enable_cloudtrail ? 1 : 0
  name  = "${local.project_slug}-cloudtrail-cw-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "cloudtrail_to_cw" {
  count = var.enable_cloudtrail ? 1 : 0
  name  = "${local.project_slug}-cloudtrail-cw-policy"
  role  = aws_iam_role.cloudtrail_to_cw[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.cloudtrail[0].arn}:*"
      }
    ]
  })
}

resource "aws_cloudtrail" "organization_trail" {
  count                         = var.enable_cloudtrail ? 1 : 0
  name                          = "${local.project_slug}-trail"
  s3_bucket_name                = aws_s3_bucket.security_logs.id
  kms_key_id                    = var.use_customer_managed_kms ? aws_kms_key.cloudtrail[0].arn : null
  sns_topic_name                = aws_sns_topic.security_alerts.name
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_logging                = true
  enable_log_file_validation    = true

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail[0].arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_to_cw[0].arn

  depends_on = [
    aws_s3_bucket_policy.security_logs,
    aws_sns_topic_policy.security_alerts
  ]

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "cloudtrail_errors" {
  count               = var.enable_cloudtrail ? 1 : 0
  alarm_name          = "${local.project_slug}-cloudtrail-errors"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "DeliveryErrors"
  namespace           = "AWS/CloudTrail"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "CloudTrail delivery errors detected"
  alarm_actions       = [aws_sns_topic.security_alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    TrailName = aws_cloudtrail.organization_trail[0].name
  }

  tags = local.common_tags
}

resource "aws_iam_account_password_policy" "strict" {
  minimum_password_length        = 14
  require_lowercase_characters   = true
  require_uppercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
  max_password_age               = 90
  password_reuse_prevention      = 24
  hard_expiry                    = false
}

resource "aws_kms_key" "env" {
  for_each = var.use_customer_managed_kms ? local.environments : toset([])

  description             = "KMS key for ${var.project_name}-${each.key}"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  tags = merge(local.common_tags, { Environment = each.key })
}

resource "aws_kms_alias" "env" {
  for_each = var.use_customer_managed_kms ? local.environments : toset([])

  name          = "alias/${local.project_slug}-${each.key}"
  target_key_id = aws_kms_key.env[each.key].key_id
}
