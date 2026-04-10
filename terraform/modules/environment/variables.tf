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
  type = string
}

variable "central_log_bucket_id" {
  type = string
}

variable "central_log_bucket_arn" {
  type = string
}

variable "security_alerts_topic" {
  type = string
}

variable "tags" {
  type = map(string)
}
