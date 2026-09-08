locals {
  common_tags = {
    ManagedBy   = "Terraform"
    Environment = var.environment
  }

  on_premises_clusters = {
    dev = {
      endpoint = var.premises.cluster_dev_endpoint
      ca = var.premises.cluster_dev_ca
    }
    prod = {
      endpoint = var.premises.cluster_prod_endpoint
      ca = var.premises.cluster_dev_ca
    }
  }
  # Host del emisor OIDC del cluster, sin esquema. Es la clave sobre la que se
  # construyen las condiciones sub/aud de cualquier trust policy IRSA.
  oidc_issuer_host = replace(var.eks.oidc_provider_url, "https://", "")
}
