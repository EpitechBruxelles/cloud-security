output "public_instance_id" {
  value = aws_instance.public.id
}

output "public_instance_public_dns" {
  value = aws_instance.public.public_dns
}

output "public_instance_public_ip" {
  value = aws_instance.public.public_ip
}

output "app_instance_id" {
  value = var.enable_private_app_tier ? aws_instance.app[0].id : null
}

output "rds_endpoint" {
  value = var.enable_rds ? aws_db_instance.main[0].endpoint : null
}

output "app_bucket_name" {
  value = aws_s3_bucket.app_data.id
}

output "cloudfront_domain_name" {
  value = var.enable_cloudfront ? aws_cloudfront_distribution.public[0].domain_name : null
}

output "cloudfront_distribution_id" {
  value = var.enable_cloudfront ? aws_cloudfront_distribution.public[0].id : null
}
