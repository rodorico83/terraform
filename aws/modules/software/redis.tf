# Namespace para Redis
resource "kubernetes_namespace" "redis" {
  count      = var.enable_redis ? 1 : 0
  metadata {
    name = "redis"
    labels = { "ambient.istio.io/redirection" = "enabled" }
  }
}

# Secreto externo para Redis sincronizado desde AWS Secrets Manager
resource "kubectl_manifest" "redis_external_secret" {
  validate_schema = false
  count      = var.enable_redis ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "redis-secret"
      namespace = kubernetes_namespace.redis[0].metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "aws-secretsmanager"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "redis-secret-k8s"
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "redis-password"
          remoteRef = {
            key      = "apps/redis/credentials"
            property = "password"
          }
        }
      ]
    }
  })
  depends_on      = [kubernetes_namespace.redis, kubectl_manifest.cluster_secret_store]
}

# Despliegue de Redis usando Helm
resource "helm_release" "redis" {
  name             = "redis-cluster"
  repository       = "oci://registry-1.docker.io/bitnamicharts"
  chart            = "redis"
  version          = "28.3.1" # Asegura la versión estable deseada
  namespace        = kubernetes_namespace.redis[0].metadata[0].name
  create_namespace = false
  count      = var.enable_redis ? 1 : 0
  values = [
    yamlencode({
      architecture =  "replication" # "standalone"
      auth = {
        enabled                   = true
        existingSecret            = "redis-secret-k8s"
        existingSecretPasswordKey = "redis-password"
      }
      # Parámetros avanzados de Redis (Protección OOM y AOF)
      # maxmemory-policies:
      #   Least Recently Used: allkeys-lru, volatile-lru (only those with TTL)
      #   Least Frequently Used: allkeys-lfu volatile-lfu
      #   Ramdom: allkeys-random, volatile-random,
      #   TTL based: volatile-ttl
      #   noeviction (Rejects all writes)
      # appendonly: Redis registra cada operación de escritura (SET, DEL, etc.) en un fichero, garatiza durabilidad si pod muere
      # appendfsync everysec: sync registro con file every sec
      commonConfiguration: <<-EOT
        maxmemory 900mb
        maxmemory-policy allkeys-lru
        appendonly yes
        appendfsync everysec
        #rename-command FLUSHALL SECURE_FLUSHALL_DISABLED
        #rename-command FLUSHDB SECURE_FLUSHDB_DISABLED
        #rename-command CONFIG SECURE_CONFIG_DISABLED
      EOT

      master = {
        nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
        priorityClassName = "system-cluster-critical"
        persistence = {
          enabled      = true
          storageClass = "gp3"
          size         = "8Gi"
        }
        resources = {
          requests = { cpu = "100m", memory = "512Mi" }
          limits   = { cpu = "500m", memory = "1Gi" }
        }
        podAntiAffinityPreset = "hard"
        topologySpreadConstraints = [
          {
            maxSkew           = 1
            topologyKey       = "topology.kubernetes.io/zone"
            whenUnsatisfiable = "DoNotSchedule"
            labelSelector = {
              matchLabels = { "app.kubernetes.io/name" = "redis" }
            }
          }
        ]
      }
      replica = {
        replicaCount = 2
        nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
        priorityClassName = "system-cluster-critical"
        persistence = {
          enabled      = true
          storageClass = "gp3"
          size         = "8Gi"
        }
        resources = {
          requests = { cpu = "100m", memory = "128Mi" }
          limits   = { cpu = "500m", memory = "1Gi" }
        }
        podAntiAffinityPreset = "hard"
      }
      # Redis Sentinel para Failover Automático
      sentinel = {
        enabled      = true
        resources = {
          requests = { cpu = "50m", memory = "64Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }
      podDisruptionBudget = {
        enabled      = true
        minAvailable = 1
      }
      metrics = {
        enabled = true
        resources = {
          requests = { cpu = "50m", memory = "64Mi" }
          limits   = { cpu = "100m", memory = "128Mi" }
        }
        serviceMonitor = {
          enabled = true
          namespace = kubernetes_namespace.redis[0].metadata[0].name
          interval  = "15s"
          labels    = { release = "kube-prometheus-stack" }
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace.redis, kubectl_manifest.redis_external_secret,kubectl_manifest.karpenter_node_pool_infra]
}