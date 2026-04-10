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

variable "admin_email" {
  description = "Security alerts destination email."
  type        = string
}

variable "tags" {
  description = "Additional tags for shared resources."
  type        = map(string)
  default     = {}
}
