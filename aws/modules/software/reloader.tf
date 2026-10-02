# Stakater Reloader to update argocd apps in case of secrets updates
resource "helm_release" "reloader" {
  count            = var.enable_reloader ? 1 : 0
  name             = "reloader"
  repository       = "https://stakater.github.io/stakater-charts"
  chart            = "reloader"
  version          = "2.2.16"
  namespace        = "reloader"
  create_namespace = true

  /*set {
    name  = "reloader.watchGlobally"
    value = "true"
  }*/

  values = [
    jsonencode({
      # Fijamos las réplicas para que NO escale dinámicamente
      replicaCount = 1
      watchGlobally = true
      common = { reloadStrategy = "annotations" }
      nodeSelector = { "eks.amazonaws.com/nodegroup" = "private-workers" }

      # ─── EL TECHO DE CRISTAL (RESOURCE LIMITS) ───
      resources = {
        requests = {
          cpu    = "50m" # Reserva solo el 10% de un núcleo de CPU
          memory = "128Mi"
        }
        limits = {
          cpu    = "200m"  # Jamás le permitas pasarse del 20%
          memory = "256Mi" # Si el proceso intenta consumir más, Kubernetes lo frena
        }
      }

    })
  ]

}