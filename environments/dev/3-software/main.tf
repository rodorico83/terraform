variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "environment" {
  type    = string
  default = "dev"
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

# Fetch Platform Layer state for Dev
data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = "example-tfstate-storage-2026"
    key    = "dev/platform/terraform.tfstate"
    region = var.aws_region
  }
}

variable "enable_github_oidc" {
  type    = bool
  default = true
}

variable "github_repository" {
  type    = string
  default = "my-enterprise-org/my-infra-repo"
}

module "software" {
  source = "../../../modules/software"

  environment          = var.environment
  enable_argocd        = true
  enable_reloader      = true
  enable_ingress_nginx = true
  enable_cert_manager  = true

  vpc = {
    vpc_id       = data.terraform_remote_state.network.outputs.vpc.id
  }

  premises = {
    on_prem_cidr = data.terraform_remote_state.network.outputs.vpc.on_prem_cidr
  }

  eks ={
    cluster_name = data.terraform_remote_state.platform.outputs.eks.name
    cluster_endpoint = data.terraform_remote_state.platform.outputs.eks.endpoint
    oidc_provider_arn = data.terraform_remote_state.platform.outputs.eks.oidc_arn
    oidc_provider_url = data.terraform_remote_state.platform.outputs.eks.oidc_url
    node_role_arn = data.terraform_remote_state.platform.outputs.eks.node_role_arn
    pod_app_sg = data.terraform_remote_state.platform.outputs.eks.pod_app_sg
  }

  db = {
    db_port           = data.terraform_remote_state.platform.outputs.db.port
    sg_group_db_id    = data.terraform_remote_state.platform.outputs.db.sg_group
    database_subnet_group_id  = data.terraform_remote_state.platform.outputs.db.subnet_group_id

  }

  nlb_scheme = "internet-facing"
  enable_github_oidc = var.enable_github_oidc
  github_repository  = var.github_repository

  #vpc_id       = data.terraform_remote_state.network.outputs.vpc.id
  #cluster_name           = data.terraform_remote_state.platform.outputs.eks.name
  #oidc_provider_arn      = data.terraform_remote_state.platform.outputs.eks.oidc_arn
  #node_security_group_id = data.terraform_remote_state.platform.outputs.eks.cluster_sg
  #sg_group_db_id = data.terraform_remote_state.platform.outputs.db.sg_group
  #db_port        = data.terraform_remote_state.platform.outputs.db.port


}
