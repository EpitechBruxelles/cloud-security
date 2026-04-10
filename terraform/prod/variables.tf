variable "project_name" {
  description = "Project prefix used in resource names."
  type        = string
  default     = "cool-delivery"
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
  default     = "t2.micro"
}

variable "tags" {
  description = "Additional tags for this environment."
  type        = map(string)
  default     = {}
}
