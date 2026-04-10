output "security_logs_bucket" {
  description = "Central security log bucket name."
  value       = aws_s3_bucket.security_logs.id
}

output "cloudtrail_name" {
  description = "CloudTrail trail name."
  value       = aws_cloudtrail.organization_trail.name
}

output "public_instances" {
  description = "Public instance metadata by environment."
  value = {
    for env, m in module.environment :
    env => {
      instance_id = m.public_instance_id
      public_dns  = m.public_instance_public_dns
      public_ip   = m.public_instance_public_ip
    }
  }
}

output "app_instances" {
  description = "Private app instance IDs by environment."
  value = {
    for env, m in module.environment : env => m.app_instance_id
  }
}

output "rds_endpoints" {
  description = "RDS endpoints by environment."
  value = {
    for env, m in module.environment : env => m.rds_endpoint
  }
}

output "s3_data_buckets" {
  description = "Per-environment S3 bucket names."
  value = {
    for env, m in module.environment : env => m.app_bucket_name
  }
}
