terraform {
  required_version = ">= 1.5.0"
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
      configuration_aliases = [helm.onprem]
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31.0"
    }
    # ─── AGREGAMOS EL PROVEEDOR DE INFRAESTRUCTURA DE ESCALADO ───
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14.0"
    }
    grafana = {
      source  = "grafana/grafana"
      version = ">= 2.0.0"
    }
    http = {
      source  = "hashicorp/http"
      version = ">= 3.0.0"
    }
    /*wiz = {
      source  = "tf.app.wiz.io/wizsec/wiz" # Proveedor oficial de Wiz
      version = "~> 1.22"
    }*/

  }
}
