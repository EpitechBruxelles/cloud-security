output "public_instance_id" {
  value = module.environment.public_instance_id
}

output "public_instance_public_dns" {
  value = module.environment.public_instance_public_dns
}

output "public_instance_public_ip" {
  value = module.environment.public_instance_public_ip
}

output "app_instance_id" {
  value = module.environment.app_instance_id
}

output "rds_endpoint" {
  value = module.environment.rds_endpoint
}

output "app_bucket_name" {
  value = module.environment.app_bucket_name
}

output "cloudfront_domain_name" {
  value = module.environment.cloudfront_domain_name
}

output "cloudfront_distribution_id" {
  value = module.environment.cloudfront_distribution_id
}
