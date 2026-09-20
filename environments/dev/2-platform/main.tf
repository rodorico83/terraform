variable "aws_region" {
  type    = string
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
  default = "rodorico83/terraform"
}

# Fetch Network Layer state for Dev
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "example-tfstate-storage"
    key    = "dev/network/terraform.tfstate"
    region = var.aws_region
  }
}

module "platform" {
  source = "../../../modules/platform"

  /*providers = {
    kubernetes.aws_eks = kubernetes
  }*/

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
    desired_size = 6
    min_size     = 6
    max_size     = 6
    node_capacity_type       = var.node_capacity_type
    node_instance_types      = var.node_instance_types
    enable_pod_eni = false
  }

  db_config = {
    engine         = "postgres"
    engine_version = "18.6"
    instance_class = "db.t4g.micro"
    port           = 5432
    database_name  = "example_dev"
    admin_username = "db_admin_dev"
  }


}
