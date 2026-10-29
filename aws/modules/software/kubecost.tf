# 1. Crear el namespace dedicado para Kubecost
resource "kubernetes_namespace" "kubecost" {
  count = var.enable_finops ? 1 : 0

  metadata {
    name = "kubecost"
    labels = { "app.kubernetes.io/managed-by" = "terraform" }
  }
}

# 2. Desplegar Kubecost 3.3.0 usando el Helm Release oficial v3
resource "helm_release" "kubecost" {
  count      = var.enable_finops ? 1 : 0
  name       = "kubecost"
  # 🎯 CAMBIO V3: Nuevo repositorio y nombre de chart
  repository = "https://kubecost.github.io/kubecost/"
  chart      = "kubecost"
  version    = "3.3.0"
  namespace  = kubernetes_namespace.kubecost[0].metadata[0].name

  values = [
    yamlencode({
      kubecostToken = "a3ViZWNvc3RfZGV2X3Rva2Vu"

      global = {
        currency  = "USD"
        clusterId = var.eks.cluster_name
      }

      # 🎯 Exportar métricas hacia tu Prometheus Operator para verlas en Grafana
      serviceMonitor = {
        enabled = true
        additionalLabels = { release = "kube-prometheus-stack" }
      }

      resources = {
        requests = {
          cpu    = "100m"
          memory = "128Mi"
        }
        limits = {
          cpu    = "250m"
          memory = "512Mi"
        }
      }

      # 🎯 Ingress con TLS y Let's Encrypt
      ingress = {
        enabled   = true
        className = "nginx"
        annotations = {
          "cert-manager.io/cluster-issuer"               = "letsencrypt-${var.environment}"
          "nginx.ingress.kubernetes.io/backend-protocol" = "HTTP"
          "nginx.ingress.kubernetes.io/ssl-redirect"     = "true"
        }
        hosts = ["kubecost.aws.rj-engineering.com"]
        paths    = ["/"]
        pathType = "Prefix"
        tls = [
          {
            hosts      = ["kubecost.aws.rj-engineering.com"]
            secretName = "kubecost-tls-secret"
          }
        ]
      }

      # 🎯 Almacenamiento persistente en gp3 para el histórico de costes
      persistentVolume = {
        enabled      = true
        storageClass = "gp3"
        size         = "10Gi"
      }
      # 🎯 Despliegue en instancias Spot
      nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
    })
  ]

  depends_on = [
    kubernetes_namespace.kubecost,
    helm_release.kube_prometheus_stack,
    helm_release.cert_manager,
    kubectl_manifest.karpenter_node_pool_infra
  ]
}