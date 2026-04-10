data "terraform_remote_state" "shared" {
  backend = "local"

  config = {
    path = "../shared/terraform.tfstate"
  }
}

locals {
  environment = "staging"

  common_tags = merge(
    {
      Project   = var.project_name
      ManagedBy = "Terraform"
      Security  = "Baseline"
    },
    var.tags,
    {
      Environment = local.environment
    }
  )
}

module "environment" {
  source = "../modules/environment"

  project_name           = var.project_name
  environment            = local.environment
  aws_region             = var.aws_region
  vpc_cidr               = "10.1.0.0/16"
  public_subnet_cidr     = "10.1.1.0/24"
  app_subnet_cidr        = "10.1.2.0/24"
  db_subnet_a_cidr       = "10.1.3.0/24"
  db_subnet_b_cidr       = "10.1.4.0/24"
  db_backup_retention    = 3
  db_engine              = var.db_engine
  db_allocated_storage   = var.db_allocated_storage
  instance_type          = var.instance_type
  kms_key_arn            = data.terraform_remote_state.shared.outputs.env_kms_key_arns[local.environment]
  central_log_bucket_id  = data.terraform_remote_state.shared.outputs.central_log_bucket_id
  central_log_bucket_arn = data.terraform_remote_state.shared.outputs.central_log_bucket_arn
  security_alerts_topic  = data.terraform_remote_state.shared.outputs.security_alerts_topic_arn
  tags                   = local.common_tags
}
