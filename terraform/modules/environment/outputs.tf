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
  value = aws_instance.app.id
}

output "rds_endpoint" {
  value = aws_db_instance.main.endpoint
}

output "app_bucket_name" {
  value = aws_s3_bucket.app_data.id
}
