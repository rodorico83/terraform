variable "aws_region" {
  type    = string
  default = "eu-south-2"
}

variable "environment" {
  type    = string
  default = "dev"
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

# Fetch Platform Layer state for Dev
data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = "example-tfstate-storage"
    key    = "dev/platform/terraform.tfstate"
    region = var.aws_region
  }
}

variable "enable_github_oidc" {
  type    = bool
  default = true
}

variable "enable_istio" {
  type    = bool
  default = false
}

variable "enable_finops" {
  type        = bool
  default     = false
  description = "Whether to enable Prometheus/grafana stack"
}

variable "enable_monitoring" {
  type        = bool
  default     = false
  description = "Whether to enable Prometheus/grafana stack"
}

variable "github_repository" {
  type    = string
  default = "my-enterprise-org/my-infra-repo"
}

variable "github_read_token" {
  type    = string
}

variable "on_prem_cluster_ca_cert" {
  type    = string
  default = null
}


variable "on_prem_cluster_token" {
  type    = string
  default = null
}

variable "on_prem_cluster_endpoint" {
  type    = string
  default = null
}


/*variable "wiz" {
  type = object({
    enable         = bool
    client_id      = string
    client_secret  = string
    sensor_token   = string
  })

  description = "wiz configuration"
}*/

module "software" {
  source = "../../../modules/software"

  environment          = var.environment
  enable_argocd        = true
  enable_reloader      = true
  enable_ingress_nginx = true
  enable_cert_manager  = true
  enable_istio         = var.enable_istio
  enable_monitoring    = true
  enable_eck           = false
  enable_finops        = var.enable_finops
  enable_redis         = true
  enable_rabbitmq      = true

  app_namespace = var.environment

  providers = { helm.onprem = helm.onprem }

  vpc = {
    vpc_id = data.terraform_remote_state.network.outputs.vpc.id
    private_subnet_ids = data.terraform_remote_state.network.outputs.vpc.private_subnet_ids
    database_subnet_group_id = data.terraform_remote_state.network.outputs.vpc.database_subnet_group_id
  }
  nlb_scheme = "internet-facing"

  premises = {
    on_prem_cidr = data.terraform_remote_state.network.outputs.vpc.on_prem_cidr
    cluster_prod_endpoint = ""
    cluster_dev_endpoint = ""
    cluster_prod_ca = ""
    cluster_dev_ca = ""
  }

  eks = {
    cluster_name      = data.terraform_remote_state.platform.outputs.eks.name
    cluster_endpoint  = data.terraform_remote_state.platform.outputs.eks.endpoint
    oidc_provider_arn = data.terraform_remote_state.platform.outputs.eks.oidc_arn
    oidc_provider_url = data.terraform_remote_state.platform.outputs.eks.oidc_url
    oidc_issuer       = data.terraform_remote_state.platform.outputs.eks.oidc_issuer
    node_role_arn     = data.terraform_remote_state.platform.outputs.eks.node_role_arn
    pod_app_sg        = data.terraform_remote_state.platform.outputs.eks.pod_app_sg
    node_sg           = data.terraform_remote_state.platform.outputs.eks.node_sg
    ca_certificate = base64decode(data.terraform_remote_state.platform.outputs.eks.cert)
    cluster_sg        = data.terraform_remote_state.platform.outputs.eks.cluster_sg
  }

  db = {
    db_port                  = data.terraform_remote_state.platform.outputs.db.port
    sg_group_db_id           = data.terraform_remote_state.platform.outputs.db.sg_group
    database_subnet_group_id = data.terraform_remote_state.platform.outputs.db.subnet_group_id
    name                     = data.terraform_remote_state.platform.outputs.db.name
    endpoint                 = data.terraform_remote_state.platform.outputs.db.endpoint
    username                 = data.terraform_remote_state.platform.outputs.db.username
  }

  github = {
    enable_github_oidc = var.enable_github_oidc
    github_repository  = var.github_repository
    read_token = var.github_read_token
  }



  /*wiz = {
    enable         = var.wiz.enable
    client_id      = var.wiz.client_id
    client_secret  = var.wiz.client_secret
    sensor_token   = var.wiz.sensor_token
  }*/

  #vpc_id       = data.terraform_remote_state.network.outputs.vpc.id
  #cluster_name           = data.terraform_remote_state.platform.outputs.eks.name
  #oidc_provider_arn      = data.terraform_remote_state.platform.outputs.eks.oidc_arn
  #node_security_group_id = data.terraform_remote_state.platform.outputs.eks.cluster_sg
  #sg_group_db_id = data.terraform_remote_state.platform.outputs.db.sg_group
  #db_port        = data.terraform_remote_state.platform.outputs.db.port
}
