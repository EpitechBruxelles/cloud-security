variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "public_subnet_cidr" {
  type = string
}

variable "app_subnet_cidr" {
  type = string
}

variable "db_subnet_a_cidr" {
  type = string
}

variable "db_subnet_b_cidr" {
  type = string
}

variable "db_backup_retention" {
  type = number
}

variable "db_engine" {
  type = string
}

variable "db_allocated_storage" {
  type = number
}

variable "instance_type" {
  type = string
}

variable "kms_key_arn" {
  type     = string
  default  = null
  nullable = true
}

variable "central_log_bucket_id" {
  type     = string
  default  = null
  nullable = true
}

variable "central_log_bucket_arn" {
  type     = string
  default  = null
  nullable = true
}

variable "security_alerts_topic" {
  type     = string
  default  = null
  nullable = true
}

variable "demo_mode" {
  type    = bool
  default = false
}

variable "enable_private_app_tier" {
  type    = bool
  default = true
}

variable "enable_rds" {
  type    = bool
  default = true
}

variable "enable_cloudfront" {
  type    = bool
  default = true
}

variable "enable_interface_endpoints" {
  type    = bool
  default = true
}

variable "enable_flow_logs" {
  type    = bool
  default = true
}

variable "enable_security_alarms" {
  type    = bool
  default = true
}

variable "enable_centralized_s3_access_logs" {
  type    = bool
  default = true
}

variable "enable_detailed_monitoring" {
  type    = bool
  default = true
}

variable "rds_deletion_protection" {
  type    = bool
  default = true
}

variable "rds_skip_final_snapshot" {
  type    = bool
  default = false
}

variable "tags" {
  type = map(string)
}
