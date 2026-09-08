# 1. Argo CD
resource "helm_release" "argocd" {
  count            = (var.enable_argocd && var.environment == "prod") ? 1 : 0
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.16.0"
  namespace        = "argocd"
  create_namespace = true

  values = [
    yamlencode({
      configs = {
        clusters = [
          {
            name   = "${var.environment}-aws-cluster"
            server = var.eks.cluster_endpoint

            # 🎯 SÍ ES POSIBLE: Añade las labels aquí mismo
            labels = {
              environment = var.environment
              provider    = "aws"
            }

            config = {
              tlsClientConfig = {
                insecure = false
                caData   = var.eks.ca_certificate
              }
            }
          },
          {
            name   = "${var.environment}-onprem-cluster"
            server = local.on_premises_clusters[var.environment].endpoint

            # 🎯 Etiquetas para tu clúster físico / local
            labels = {
              environment = var.environment
              provider    = "onprem"
            }

            config = {
              tlsClientConfig = {
                insecure = false
                caData   = local.on_premises_clusters[var.environment].ca
              }
            }
          }
        ]
      }
    })
  ]

}