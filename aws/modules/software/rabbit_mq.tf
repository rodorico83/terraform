# Namespace para RabbitMQ
resource "kubernetes_namespace" "rabbitmq" {
  metadata {
    name = "rabbitmq"
    labels = { "istio.io/dataplane-mode"   = "ambient" }
  }
}

# Secreto externo para RabbitMQ sincronizado desde AWS Secrets Manager
resource "kubectl_manifest" "rabbitmq_external_secret" {
  validate_schema = false
  count      = var.enable_rabbitmq ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "rabbitmq-secret"
      namespace = kubernetes_namespace.rabbitmq.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "aws-secretsmanager"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "rabbitmq-secret-k8s"
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "rabbitmq-password"
          remoteRef = {
            key      = "apps/rabbitmq/credentials"
            property = "password"
          }
        },
        {
          secretKey = "rabbitmq-erlang-cookie"
          remoteRef = {
            key      = "apps/rabbitmq/credentials"
            property = "erlang-cookie"
          }
        }
      ]
    }
  })
  depends_on = [kubernetes_namespace.rabbitmq,kubectl_manifest.cluster_secret_store]
}

# Despliegue de RabbitMQ usando Helm
resource "helm_release" "rabbitmq" {
  name             = "rabbitmq-cluster"
  repository       = "oci://registry-1.docker.io/bitnamicharts"
  chart            = "rabbitmq"
  version          = "15.2.0"
  namespace        = kubernetes_namespace.rabbitmq.metadata[0].name
  create_namespace = false
  count      = var.enable_rabbitmq ? 1 : 0
  values = [
    yamlencode({
      global = {
        security = { allowInsecureImages = true }
      }
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/rabbitmq"
        tag        = "4.0.4-debian-12-r1"
      }
      auth = {
        username                  = "admin"
        existingPasswordSecret    = "rabbitmq-secret-k8s"
        existingSecretPasswordKey = "rabbitmq-password"
        existingErlangSecret      = "rabbitmq-secret-k8s"
        existingSecretErlangKey   = "rabbitmq-erlang-cookie"
        updatePassword            = true # Fuerza a RabbitMQ a actualizar la contraseña existente en el disco
      }
      replicaCount = 2 # Incrementar a 3 para producción en cluster distribuido
      nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
      podAntiAffinityPreset = "hard" # Obliga a que cada pod esté en un nodo EC2 distinto
      topologySpreadConstraints = [
        {
          maxSkew           = 1
          topologyKey       = "topology.kubernetes.io/zone"
          whenUnsatisfiable = "DoNotSchedule"
          labelSelector = { matchLabels = { "app.kubernetes.io/name" = "rabbitmq" } }
        }
      ]
      podDisruptionBudget = {
        enabled      = true
        minAvailable = 1 # Mantiene siempre quórum de 2 nodos durante upgrades
      }
      # Parámetros de clúster, memoria y particiones de red
      extraConfiguration = <<-EOT
        # Pause disconnected (from quorum) nodes to avoid data corruption or loose messages
        #cluster_partition_handling = pause_minority
        # Memory limit for blocking producers (backpressure) to avoid OOM
        vm_memory_high_watermark.relative = 0.85
        # free disk in relation with requested memory to block producers (backpressure)
        #disk_free_limit.relative = 1.5
        # Block guess user if not from localhost, requiring auth
        loopback_users.guest = false
      EOT

      persistence = {
        enabled      = true
        storageClass = "gp3"
        size         = "10Gi"
      }
      resources = {
        requests = { cpu = "250m", memory = "512Mi" }
        limits   = { cpu = "1000m", memory = "1Gi" }
      }
      metrics = {
        enabled = true
        serviceMonitor = {
          enabled   = true
          namespace = kubernetes_namespace.rabbitmq.metadata[0].name
          interval  = "15s"
          labels    = { release = "kube-prometheus-stack" }
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace.rabbitmq,
    kubectl_manifest.rabbitmq_external_secret[0],
    kubectl_manifest.karpenter_node_pool_infra]
}