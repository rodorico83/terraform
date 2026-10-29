# Stakater Reloader to update argocd apps in case of secrets updates
# Automatically creates the proper cluster role to update k8s secrets
resource "helm_release" "reloader" {
  count            = var.enable_reloader ? 1 : 0
  name             = "reloader"
  repository       = "https://stakater.github.io/stakater-charts"
  chart            = "reloader"
  version          = "2.2.16"
  namespace        = "reloader"
  create_namespace = true

  values = [
    jsonencode({
      replicaCount = 1
      watchGlobally = true
      common = { reloadStrategy = "annotations" }
      nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }

      deployment = {
        resources = {
          requests = {
            cpu    = "50m"
            memory = "128Mi"
          }
          limits = {
            cpu    = "200m"
            memory = "256Mi"
          }
        }
      }

    })
  ]
  depends_on = [kubectl_manifest.karpenter_node_pool_infra]
}