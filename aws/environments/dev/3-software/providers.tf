terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14.0"
    }
    wiz = {
      source  = "tf.app.wiz.io/wizsec/wiz" # Proveedor oficial de Wiz
      version = "~> 1.22"
    }
  }

  backend "s3" {
    bucket         = "example-tfstate-storage"
    key            = "dev/software/terraform.tfstate"
    region         = "eu-south-2"
    use_lockfile = true # <--- Reemplaza dynamodb_table on Terraform (v1.11+)
    #dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

provider "helm" {
  kubernetes {
    host                   = data.terraform_remote_state.platform.outputs.eks.endpoint
    cluster_ca_certificate = base64decode(data.terraform_remote_state.platform.outputs.eks.cert)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", data.terraform_remote_state.platform.outputs.eks.name]
      command     = "aws"
    }
  }
}

# Kubernetes Provider for your On-Premises Cluster (Aliased)
provider "helm" {
  alias = "onprem"
  kubernetes {
    host = var.on_prem_cluster_endpoint # Tu IP y puerto interno a través de la VPN "https://corp.local:6443"

    # MODO PIPELINE: Si las variables traen datos, se autentica directamente
    token = var.on_prem_cluster_token
    cluster_ca_certificate = var.on_prem_cluster_ca_cert != null ? base64decode(var.on_prem_cluster_ca_cert) : null

    # MODO DEVOPS LOCAL: Si las variables están vacías, recurre a tu contexto de kubectl local
    config_path    = var.on_prem_cluster_token == null ? "~/.kube/config" : null
    config_context = var.on_prem_cluster_token == null ? "onprem-cluster-context" : null
  }
}

provider "kubernetes" {
  host                   = data.terraform_remote_state.platform.outputs.eks.endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.platform.outputs.eks.cert)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", data.terraform_remote_state.platform.outputs.eks.name]
    command     = "aws"
  }
}

# Kubernetes Provider for your On-Premises Cluster (Aliased)
provider "kubernetes" {
  alias = "onprem"
  host  = var.on_prem_cluster_endpoint # Tu IP y puerto interno a través de la VPN "https://corp.local:6443"

  # MODO PIPELINE: Si las variables traen datos, se autentica directamente
  token                  = var.on_prem_cluster_token
  cluster_ca_certificate = var.on_prem_cluster_ca_cert != null ? base64decode(var.on_prem_cluster_ca_cert) : null

  # MODO DEVOPS LOCAL: Si las variables están vacías, recurre a tu contexto de kubectl local
  config_path    = var.on_prem_cluster_token == null ? "~/.kube/config" : null
  config_context = var.on_prem_cluster_token == null ? "onprem-cluster-context" : null
}


provider "kubectl" {
  host                   = data.terraform_remote_state.platform.outputs.eks.endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.platform.outputs.eks.cert)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", data.terraform_remote_state.platform.outputs.eks.name]
  }
}

/*provider "wiz" {
  client_id     = var.wiz.client_id
  client_secret = var.wiz.client_secret
}*/
