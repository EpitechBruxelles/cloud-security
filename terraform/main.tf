provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  project_slug = replace(replace(lower(var.project_name), "/[^a-z0-9-]/", "-"), "/-+/", "-")

  common_tags = merge(
    {
      Project   = var.project_name
      ManagedBy = "Terraform"
      Security  = "Baseline"
    },
    var.tags
  )

  environments = {
    dev = {
      vpc_cidr           = "10.2.0.0/16"
      public_subnet_cidr = "10.2.1.0/24"
      app_subnet_cidr    = "10.2.2.0/24"
      db_subnet_a_cidr   = "10.2.3.0/24"
      db_subnet_b_cidr   = "10.2.4.0/24"
      backup_retention   = 3
    }
    staging = {
      vpc_cidr           = "10.1.0.0/16"
      public_subnet_cidr = "10.1.1.0/24"
      app_subnet_cidr    = "10.1.2.0/24"
      db_subnet_a_cidr   = "10.1.3.0/24"
      db_subnet_b_cidr   = "10.1.4.0/24"
      backup_retention   = 3
    }
    prod = {
      vpc_cidr           = "10.0.0.0/16"
      public_subnet_cidr = "10.0.1.0/24"
      app_subnet_cidr    = "10.0.2.0/24"
      db_subnet_a_cidr   = "10.0.3.0/24"
      db_subnet_b_cidr   = "10.0.4.0/24"
      backup_retention   = 7
    }
  }
}

resource "aws_sns_topic" "security_alerts" {
  name              = "${local.project_slug}-security-alerts"
  kms_master_key_id = "alias/aws/sns"

  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "security_email" {
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = var.admin_email
}

resource "aws_kms_key" "cloudtrail" {
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

  tags = merge(local.common_tags, { Scope = "shared" })
}

resource "aws_kms_alias" "cloudtrail" {
  name          = "alias/${local.project_slug}-cloudtrail"
  target_key_id = aws_kms_key.cloudtrail.key_id
}

resource "aws_s3_bucket" "security_logs" {
  bucket        = "${local.project_slug}-security-logs-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.name}"
  force_destroy = false

  tags = merge(local.common_tags, { DataClass = "audit" })
}

resource "aws_s3_bucket_versioning" "security_logs" {
  bucket = aws_s3_bucket.security_logs.id

  versioning_configuration {
    status = "Enabled"
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
      kms_master_key_id = aws_kms_key.cloudtrail.arn
      sse_algorithm     = "aws:kms"
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
  name              = "/aws/cloudtrail/${local.project_slug}"
  retention_in_days = 90
  kms_key_id        = aws_kms_key.cloudtrail.arn

  tags = local.common_tags
}

resource "aws_iam_role" "cloudtrail_to_cw" {
  name = "${local.project_slug}-cloudtrail-cw-role"

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
  name = "${local.project_slug}-cloudtrail-cw-policy"
  role = aws_iam_role.cloudtrail_to_cw.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
      }
    ]
  })
}

resource "aws_cloudtrail" "organization_trail" {
  name                          = "${local.project_slug}-trail"
  s3_bucket_name                = aws_s3_bucket.security_logs.id
  kms_key_id                    = aws_kms_key.cloudtrail.arn
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_logging                = true
  enable_log_file_validation    = true

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_to_cw.arn

  depends_on = [aws_s3_bucket_policy.security_logs]

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "cloudtrail_errors" {
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
    TrailName = aws_cloudtrail.organization_trail.name
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
  for_each = local.environments

  description             = "KMS key for ${var.project_name}-${each.key}"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  tags = merge(local.common_tags, { Environment = each.key })
}

resource "aws_kms_alias" "env" {
  for_each = local.environments

  name          = "alias/${local.project_slug}-${each.key}"
  target_key_id = aws_kms_key.env[each.key].key_id
}

module "environment" {
  source = "./modules/environment"

  for_each = local.environments

  project_name           = var.project_name
  environment            = each.key
  aws_region             = var.aws_region
  vpc_cidr               = each.value.vpc_cidr
  public_subnet_cidr     = each.value.public_subnet_cidr
  app_subnet_cidr        = each.value.app_subnet_cidr
  db_subnet_a_cidr       = each.value.db_subnet_a_cidr
  db_subnet_b_cidr       = each.value.db_subnet_b_cidr
  db_backup_retention    = each.value.backup_retention
  db_engine              = var.db_engine
  db_allocated_storage   = var.db_allocated_storage
  instance_type          = var.instance_type
  kms_key_arn            = aws_kms_key.env[each.key].arn
  central_log_bucket_id  = aws_s3_bucket.security_logs.id
  central_log_bucket_arn = aws_s3_bucket.security_logs.arn
  security_alerts_topic  = aws_sns_topic.security_alerts.arn
  tags                   = local.common_tags
}
