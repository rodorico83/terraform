variable "mongodb_admin_password" {
  description = "Contraseña para el usuario administrador de MongoDB"
  type        = string
  sensitive   = true
  default     = "CambiaEstaContrasenaEnProd123!"
}

# ==============================================================================
# 2. NAMESPACE DEDICADO
# ==============================================================================
resource "kubernetes_namespace" "mongodb" {
  count = var.enable_mongodb_community ? 1 : 0

  metadata {
    name = "mongodb"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "istio.io/dataplane-mode"      = "ambient" # Integración opcional con Istio Ambient Mesh
    }
  }
}

# ==============================================================================
# 3. HELM RELEASE: MONGODB COMMUNITY OPERATOR
# ==============================================================================
resource "helm_release" "mongodb_operator" {
  count      = var.enable_mongodb_community ? 1 : 0
  name       = "mongodb-community-operator"
  repository = "https://mongodb.github.io/helm-charts"
  chart      = "community-operator"
  version    = "0.11.0"
  namespace  = kubernetes_namespace.mongodb[0].metadata[0].name

  values = [
    yamlencode({
      operator = {
        nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
        priorityClassName = "system-cluster-critical"
        resources = {
          requests = { cpu = "100m", memory = "128Mi" }
          limits   = { cpu = "300m", memory = "256Mi" }
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace.mongodb]
}

# ==============================================================================
# 4. SECRETOS DE AUTENTICACIÓN (ADMIN Y USUARIOS DE APLICACIÓN)
# ==============================================================================
resource "kubernetes_secret" "mongodb_admin_credentials" {
  count = var.enable_mongodb_community ? 1 : 0

  metadata {
    name      = "mongodb-admin-credentials"
    namespace = kubernetes_namespace.mongodb[0].metadata[0].name
  }

  type = "Opaque"

  data = {
    "password" = var.mongodb_admin_password
  }

  depends_on = [kubernetes_namespace.mongodb]
}

# ==============================================================================
# 5. RECURSO CRD: CLÚSTER MONGODB COMMUNITY (REPLICASET 3 NODOS EN PROD)
# ==============================================================================
resource "kubectl_manifest" "mongodb_cluster" {
  count = var.enable_mongodb_community ? 1 : 0

  validate_schema = false

  yaml_body = yamlencode({
    apiVersion = "mongodbcommunity.mongodb.com/v1"
    kind       = "MongoDBCommunity"
    metadata = {
      name      = "mongodb-production-cluster"
      namespace = kubernetes_namespace.mongodb[0].metadata[0].name
    }
    spec = {
      # Arquitectura en Alta Disponibilidad (3 miembros: 1 Primary, 2 Secondaries)
      members = 3
      type    = "ReplicaSet"
      version = "7.0.5"

      # Gestión de Autenticación SCRAM-SHA-256
      security = {
        authentication = {
          modes = ["SCRAM-SHA-256"]
        }
      }

      # Definición de Usuarios Administradores
      users = [
        {
          name = "admin"
          db   = "admin"
          passwordSecretRef = {
            name = kubernetes_secret.mongodb_admin_credentials[0].metadata[0].name
            key  = "password"
          }
          roles = [
            { name = "root", db = "admin" },
            { name = "userAdminAnyDatabase", db = "admin" }
          ]
          scramCredentialsSecretName = "mongodb-admin-scram"
        }
      ]

      # Plantilla de Pods con distribución Multi-AZ y tolerancias
      podTemplate = {
        spec = {
          # Despliegue en tus nodos de infraestructura o dedicados
          nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
          
          # Anti-Afinidad de Pods: Obliga a K8s a colocar los 3 miembros en nodos físicos diferentes
          affinity = {
            podAntiAffinity = {
              requiredDuringSchedulingIgnoredDuringExecution = [
                {
                  labelSelector = {
                    matchExpressions = [
                      {
                        key      = "app"
                        operator = "In"
                        values   = ["mongodb-production-cluster-svc"]
                      }
                    ]
                  }
                  topologyKey = "kubernetes.io/hostname"
                }
              ]
            }
          }

          containers = [
            {
              name = "mongod"
              resources = {
                requests = {
                  cpu    = "500m"
                  memory = "2Gi"
                }
                limits = {
                  cpu    = "2000m"
                  memory = "4Gi"
                }
              }
            }
          ]
        }
      }

      # Configuración del almacenamiento persistente mediante AWS EBS gp3
      statefulSet = {
        spec = {
          volumeClaimTemplates = [
            {
              metadata = {
                name = "data-volume"
              }
              spec = {
                accessModes      = ["ReadWriteOnce"]
                storageClassName = "gp3"
                resources = {
                  requests = {
                    storage = "50Gi"
                  }
                }
              }
            }
          ]
        }
      }
    }
  })

  depends_on = [
    helm_release.mongodb_operator,
    kubernetes_secret.mongodb_admin_credentials
  ]
}

# ==============================================================================
# 6. OBSERVABILIDAD: PODMONITOR PARA PROMETHEUS STACK
# ==============================================================================
# El operador despliega automáticamente un contenedor sidecar 'mongodb-exporter'
# cuando la recolección de métricas está activa.
resource "kubectl_manifest" "mongodb_pod_monitor" {
  count = var.enable_mongodb_community ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PodMonitor"
    metadata = {
      name      = "mongodb-community-metrics"
      namespace = kubernetes_namespace.mongodb[0].metadata[0].name
      labels = {
        release = "kube-prometheus-stack"
      }
    }
    spec = {
      selector = {
        matchLabels = {
          "app" = "mongodb-production-cluster-svc"
        }
      }
      podMetricsEndpoints = [
        {
          port     = "metrics"
          path     = "/metrics"
          interval = "15s"
        }
      ]
    }
  })

  depends_on = [kubectl_manifest.mongodb_cluster]
}