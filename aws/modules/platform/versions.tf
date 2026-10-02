terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31.0"
      # coredns.tf parchea el Corefile del cluster que este modulo crea.
      # El root debe pasar: providers = { kubernetes.aws_eks = kubernetes }
      #configuration_aliases = [kubernetes.aws_eks]
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    # ─── AGREGAMOS EL PROVEEDOR DE INFRAESTRUCTURA DE ESCALADO ───
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14.0"
    }
  }
}
