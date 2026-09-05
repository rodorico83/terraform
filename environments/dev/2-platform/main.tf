variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "node_capacity_type" {
  type    = string
  default = "SPOT" # 💵 Spot instances for dev to save up to 80%
}

variable "enable_github_oidc" {
  type    = bool
  default = true
}

variable "github_repository" {
  type    = string
  default = "my-enterprise-org/my-infra-repo"
}

# Fetch Network Layer state for Dev
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "example-tfstate-storage-2026"
    key    = "dev/network/terraform.tfstate"
    region = var.aws_region
  }
}

module "platform" {
  source = "../../../modules/platform"

  environment              = var.environment
  aws_region               = var.aws_region
  vpc_id                   = data.terraform_remote_state.network.outputs.vpc.id
  private_subnet_ids       = data.terraform_remote_state.network.outputs.vpc.private_subnet_ids
  database_subnet_group_id = data.terraform_remote_state.network.outputs.vpc.database_subnet_group_id
  on_prem_cidr             = data.terraform_remote_state.network.outputs.vpc.on_prem_cidr

  node_capacity_type  = var.node_capacity_type
  node_instance_types = var.node_instance_types
  scaling_config = {
    desired_size = 1
    min_size     = 1
    max_size     = 3
  }

  db_config = {
    engine         = "postgres"
    engine_version = "15.4"
    instance_class = "db.t4g.micro"
    port           = 5432
    database_name  = "example_dev"
    admin_username = "db_admin_dev"
  }

  enable_github_oidc = var.enable_github_oidc
  github_repository  = var.github_repository
}
