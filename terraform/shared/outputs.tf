output "security_alerts_topic_arn" {
  description = "SNS topic ARN used by all environments."
  value       = aws_sns_topic.security_alerts.arn
}

output "central_log_bucket_id" {
  description = "Central S3 bucket name for CloudTrail and logs."
  value       = aws_s3_bucket.security_logs.id
}

output "central_log_bucket_arn" {
  description = "Central S3 bucket ARN for CloudTrail and logs."
  value       = aws_s3_bucket.security_logs.arn
}

output "env_kms_key_arns" {
  description = "KMS key ARN per environment."
  value = {
    for env, key in aws_kms_key.env : env => key.arn
  }
}
