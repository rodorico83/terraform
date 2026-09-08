# Stakater Reloader to update argocd apps in case of secrets updates
resource "helm_release" "reloader" {
  count            = var.enable_reloader ? 1 : 0
  name             = "reloader"
  repository       = "https://stakater.github.io/stakater-charts"
  chart            = "reloader"
  version          = "v1.0.118"
  namespace        = "reloader"
  create_namespace = true

  set {
    name  = "reloader.watchGlobally"
    value = "true"
  }
}