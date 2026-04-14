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

variable "admin_email" {
  description = "Security alerts destination email."
  type        = string
}

variable "demo_mode" {
  description = "Enable cost-optimized demo mode for shared resources."
  type        = bool
  default     = false
}

variable "active_environments" {
  description = "Environment list for which shared per-env resources are created in demo mode."
  type        = set(string)
  default     = ["dev", "staging", "prod"]
}

variable "use_customer_managed_kms" {
  description = "Create customer-managed KMS keys (disabled in strict cost mode)."
  type        = bool
  default     = true
}

variable "enable_cloudtrail" {
  description = "Create CloudTrail, CloudWatch group and related IAM resources."
  type        = bool
  default     = true
}

variable "enable_security_email_subscription" {
  description = "Subscribe admin email to the SNS topic."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags for shared resources."
  type        = map(string)
  default     = {}
}
