variable "aws_region" {
  type    = string
  default = "eu-south-2"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "node_instance_types" {
  type    = list(string)
  default = ["m6i.large", "m6a.large"]
}

variable "node_capacity_type" {
  type    = string
  default = "SPOT" # 🛡️ High availability on-demand nodes
}



# Fetch Network Layer state for Prod
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "example-tfstate-storage"
    key    = "prod/network/terraform.tfstate"
    region = var.aws_region
  }
}

module "platform" {
  source = "../../../modules/platform"

  providers = {
    kubernetes.aws_eks = kubernetes
  }

  environment              = var.environment
  aws_region               = var.aws_region

  vpc = {
    vpc_id                    = data.terraform_remote_state.network.outputs.vpc.id
    private_subnet_ids        = data.terraform_remote_state.network.outputs.vpc.private_subnet_ids
    database_subnet_group_id  = data.terraform_remote_state.network.outputs.vpc.database_subnet_group_id
    enable_vpn                = data.terraform_remote_state.network.outputs.vpc.enable_vpn
  }

  premises = {
    on_prem_cidr    = data.terraform_remote_state.network.outputs.vpc.on_prem_cidr
    on_prem_domain  = data.terraform_remote_state.network.outputs.vpc.on_prem_domain
    on_prem_dns_ip  = data.terraform_remote_state.network.outputs.vpc.on_prem_dns_ip
  }

  eks = {
    desired_size = 3
    min_size     = 3
    max_size     = 3
    node_capacity_type       = var.node_capacity_type
    node_instance_types      = var.node_instance_types
  }

  db_config = {
    engine         = "postgres"
    engine_version = "15.4"
    instance_class = "db.r6g.large"
    port           = 5432
    database_name  = "production_db"
    admin_username = "db_master_admin"
  }

}
