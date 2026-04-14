variable "project_name" {
  description = "Project prefix used in resource names."
  type        = string
  default     = "CloudRuplets"
}

variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "eu-west-3"
}

variable "db_engine" {
  description = "Database engine."
  type        = string
  default     = "postgres"
}

variable "db_allocated_storage" {
  description = "RDS storage in GiB."
  type        = number
  default     = 20
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.micro"
}

variable "demo_mode" {
  description = "Enable cost-optimized demo mode."
  type        = bool
  default     = false
}

variable "enable_private_app_tier" {
  description = "Run dedicated private app instance behind public reverse proxy."
  type        = bool
  default     = true
}

variable "enable_rds" {
  description = "Enable RDS database tier."
  type        = bool
  default     = true
}

variable "enable_cloudfront" {
  description = "Enable CloudFront distribution in front of public instance."
  type        = bool
  default     = true
}

variable "enable_interface_endpoints" {
  description = "Enable interface VPC endpoints for SSM connectivity."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Enable VPC Flow Logs to CloudWatch."
  type        = bool
  default     = true
}

variable "enable_security_alarms" {
  description = "Enable CloudWatch alarms with SNS notifications."
  type        = bool
  default     = true
}

variable "enable_centralized_s3_access_logs" {
  description = "Enable S3 access logging to shared log bucket."
  type        = bool
  default     = true
}

variable "enable_detailed_monitoring" {
  description = "Enable EC2 detailed monitoring (paid metric granularity)."
  type        = bool
  default     = true
}

variable "rds_deletion_protection" {
  description = "Protect RDS deletion (disable for ephemeral demos)."
  type        = bool
  default     = true
}

variable "rds_skip_final_snapshot" {
  description = "Skip final snapshot when destroying RDS."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags for this environment."
  type        = map(string)
  default     = {}
}
