data "terraform_remote_state" "shared" {
  backend = "local"

  config = {
    path = "../shared/terraform.tfstate"
  }
}

locals {
  environment = "prod"

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

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  project_name                      = var.project_name
  environment                       = local.environment
  aws_region                        = var.aws_region
  vpc_cidr                          = "10.0.0.0/16"
  public_subnet_cidr                = "10.0.1.0/24"
  app_subnet_cidr                   = "10.0.2.0/24"
  db_subnet_a_cidr                  = "10.0.3.0/24"
  db_subnet_b_cidr                  = "10.0.4.0/24"
  db_backup_retention               = 7
  db_engine                         = var.db_engine
  db_allocated_storage              = var.db_allocated_storage
  instance_type                     = var.instance_type
  kms_key_arn                       = try(data.terraform_remote_state.shared.outputs.env_kms_key_arns[local.environment], null)
  central_log_bucket_id             = var.enable_centralized_s3_access_logs ? try(data.terraform_remote_state.shared.outputs.central_log_bucket_id, null) : null
  central_log_bucket_arn            = try(data.terraform_remote_state.shared.outputs.central_log_bucket_arn, null)
  security_alerts_topic             = var.enable_security_alarms ? try(data.terraform_remote_state.shared.outputs.security_alerts_topic_arn, null) : null
  demo_mode                         = var.demo_mode
  enable_private_app_tier           = var.enable_private_app_tier
  enable_rds                        = var.enable_rds
  enable_cloudfront                 = var.enable_cloudfront
  enable_interface_endpoints        = var.enable_interface_endpoints
  enable_flow_logs                  = var.enable_flow_logs
  enable_security_alarms            = var.enable_security_alarms
  enable_centralized_s3_access_logs = var.enable_centralized_s3_access_logs
  enable_detailed_monitoring        = var.enable_detailed_monitoring
  rds_deletion_protection           = var.rds_deletion_protection
  rds_skip_final_snapshot           = var.rds_skip_final_snapshot
  tags                              = local.common_tags
}
