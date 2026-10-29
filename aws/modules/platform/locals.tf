locals {
  common_tags = {
    ManagedBy   = "Terraform"
    Environment = var.environment
  }

  # Host del emisor OIDC del cluster, sin esquema. Es la clave sobre la que se
  # construyen las condiciones sub/aud de cualquier trust policy IRSA.
  oidc_issuer = replace(aws_iam_openid_connect_provider.eks.url, "https://", "")
}
