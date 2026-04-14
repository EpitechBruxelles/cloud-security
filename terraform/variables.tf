variable "project_name" {
  description = "Project prefix used in resource names."
  type        = string
  default     = "CloudRuplets"
}

variable "aws_region" {
  description = "Primary AWS region."
  type        = string
  default     = "eu-west-3"
}

variable "admin_email" {
  description = "Security notifications destination (SNS subscription)."
  type        = string
}

variable "db_engine" {
  description = "Database engine for all environments."
  type        = string
  default     = "postgres"

  validation {
    condition     = contains(["postgres", "mysql"], var.db_engine)
    error_message = "db_engine must be either 'postgres' or 'mysql'."
  }
}

variable "db_allocated_storage" {
  description = "Allocated storage for RDS instances in GiB."
  type        = number
  default     = 20
}

variable "instance_type" {
  description = "EC2 instance type for public and app tiers."
  type        = string
  default     = "t3.micro"
}

variable "tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
}
