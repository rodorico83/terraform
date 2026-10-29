# Namespace para Apache Kafka
resource "kubernetes_namespace" "kafka" {
  metadata {
    name = "kafka"
    labels = { "ambient.istio.io/redirection" = "disabled" }
  }
}


# Strimzi Kafka Operator (Helm Release)
# strimzi-cluster-operator:
#   reconciliar los (CRDs)  (Kafka,KafkaNodePool,KafkaClusterKafkaConnect,KafkaRebalance)
#   Ejecutar los reinicios progresivos (rolling updates) de los brokers
# kafka-cluster-entity-operator:
#   Topic Operator Container: Reconcilia los recursos KafkaTopic
#   User Operator Container: Reconcilia los recursos  KafkaUser .
#                             Gestiona la autenticación (certificados mTLS, SCRAM-SHA-512) y las ACLs
resource "helm_release" "strimzi_operator" {
  count      = var.enable_kafka ? 1 : 0
  name             = "strimzi-kafka-operator"
  repository       = "https://strimzi.io/charts/"
  chart            = "strimzi-kafka-operator"
  version          = "1.1.0"
  namespace        = kubernetes_namespace.kafka.metadata[0].name
  create_namespace = false

  values = [
    yamlencode({
      watchAnyNamespace = true
      installCRDs       = true

      resources = {
        requests = {
          cpu    = "500m"
          memory = "350Mi"
        }
        limits = {
          cpu    = "800m"
          memory = "600Mi"
        }
      }

      # Uso de yamlencode para evitar errores de escape de puntos
      nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
    })
  ]

  depends_on = [kubernetes_namespace.kafka,kubectl_manifest.karpenter_node_pool_infra]
}



# Broker:
#   Recibe los mensajes de los productores, los escribe de forma secuencial en el volumen EBS ( gp3 ), gestiona la replicación entre nodos y entrega los datos a los consumidores.
# Controller:
#   Forma parte del quórum de metadatos (el sustituto de ZooKeeper).
#   Se encarga de coordinar la topología del clúster, elegir los líderes de las particiones y gestionar las asignaciones.
resource "kubectl_manifest" "kafka_node_pool" {
  count      = var.enable_kafka ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "kafka.strimzi.io/v1"
    kind       = "KafkaNodePool"
    metadata = {
      name      = "dual-role"
      namespace = kubernetes_namespace.kafka.metadata[0].name
      labels = { "strimzi.io/cluster" = "kafka-cluster" }
    }
    spec = {
      replicas = 2
      roles    = ["controller", "broker"]

      template = {
        pod = {
          nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
          topologySpreadConstraints = [
            {
              maxSkew           = 1
              topologyKey       = "topology.kubernetes.io/zone"
              whenUnsatisfiable = "DoNotSchedule"
              labelSelector = {
                matchLabels = {
                  "strimzi.io/cluster" = "kafka-cluster"
                  "strimzi.io/name"    = "kafka-cluster-dual-role"
                }
              }
            }
          ]
          affinity = {
            podAntiAffinity = {
              requiredDuringSchedulingIgnoredDuringExecution = [
                {
                  labelSelector = {
                    matchLabels = {
                      "strimzi.io/cluster" = "kafka-cluster"
                      "strimzi.io/name"    = "kafka-cluster-dual-role"
                    }
                  }
                  topologyKey = "kubernetes.io/hostname"
                }
              ]
            }
          }
        }
      }

      storage = {
        type        = "persistent-claim"
        size        = "5Gi"
        class       = "gp3"
        deleteClaim = false
        #iops = 5000        # Subes las operaciones por segundo (por encima de las 3000 base, max 16000 on m6i, m7g o r6g)
        #throughput = 250   # Subes el ancho de banda en MB/s (por encima de los 125 MB/s base, max 1000MB/s on m6i, m7g o r6g)
      }

      resources = {
        requests = {
          memory = "1.5Gi"
          cpu    = "250m"
        }
        limits = {
          memory = "2.5Gi"
          cpu    = "600m"
        }
      }
    }
  })

  validate_schema = false
  depends_on      = [helm_release.strimzi_operator[0]]
}


resource "kubectl_manifest" "kafka_cluster" {
  count      = var.enable_kafka ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "kafka.strimzi.io/v1"
    kind       = "Kafka"
    metadata = {
      name      = "kafka-cluster"
      namespace = kubernetes_namespace.kafka.metadata[0].name
    }
    spec = {
      kafka = {
        version         = "4.3.0"
        metadataVersion = "4.3.0"
        listeners = [
          {
            name  = "plain"
            port  = 9092
            type  = "internal"
            tls   = false
          },
          {
            name  = "tls"
            port  = 9093
            type  = "internal"
            tls   = true
          }
        ]
        config = {
          "offsets.topic.replication.factor"        = 2
          "transaction.state.log.replication.factor" = 2
          "transaction.state.log.min.isr"            = 1
          "default.replication.factor"              = 2
          "min.insync.replicas"                     = 1
          "auto.create.topics.enable"               = false
          "log.retention.bytes"                     = 107374182400 # 100 GB
          "log.segment.bytes"                       = 1073741824   # 1 GB
        }
        metricsConfig = {
          type = "jmxPrometheusExporter"
          valueFrom = {
            configMapKeyRef = {
              name = "kafka-metrics-config"
              key  = "kafka-metrics-config.yml"
            }
          }
        }
      }

      cruiseControl = {
        resources = {
          requests = {
            cpu    = "100m"
            memory = "500Mi"
          }
          limits = {
            cpu    = "400m"
            memory = "700Mi"
          }
        }
      }

      kafkaExporter = {
        resources = {
          requests = {
            cpu    = "100m"
            memory = "64Mi"
          }
          limits = {
            cpu    = "300m"
            memory = "128Mi"
          }
        }
        topicRegex = ".*"
        groupRegex = ".*"
      }

      entityOperator = {
        topicOperator = {}
        userOperator  = {}
        template = {
          topicOperatorContainer = {
            resources = {
              requests = {
                cpu    = "100m"
                memory = "256Mi"
              }
              limits = {
                cpu    = "500m"
                memory = "512Mi"
              }
            }
          }
          userOperatorContainer = {
            resources = {
              requests = {
                cpu    = "100m"
                memory = "256Mi"
              }
              limits = {
                cpu    = "500m"
                memory = "512Mi"
              }
            }
          }
        }
      }
    }
  })

  validate_schema = false
  depends_on      = [kubectl_manifest.kafka_node_pool[0], kubernetes_config_map.kafka_metrics_config[0]]
}


data "http" "strimzi_jmx_metrics_config" {
  url             = "https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/${var.strimzi_version}/packaging/examples/metrics/kafka-metrics.yaml"
  request_headers = { Accept = "text/plain" }
}
resource "kubernetes_config_map" "kafka_metrics_config" {
  count      = var.enable_kafka ? 1 : 0
  metadata {
    name      = "kafka-metrics-config"
    namespace = kubernetes_namespace.kafka.metadata[0].name
  }
  data = { "kafka-metrics-config.yml" = yamldecode(split("---", data.http.strimzi_jmx_metrics_config.response_body)[3]).data["kafka-metrics-config.yml"] }
}


# ==============================================================================
# ConfigMap con reglas de exportación JMX a Prometheus
# ==============================================================================
/*resource "kubernetes_config_map" "kafka_metrics_config" {
  metadata {
    name      = "kafka-metrics-config"
    namespace = kubernetes_namespace.kafka.metadata[0].name
  }

  data = {
    "kafka-metrics-config.yml" = <<YAML
lowercaseOutputName: true
lowercaseOutputLabelNames: true
rules:
# Métricas de KRaft y Controller
- pattern: "kafka.controller<type=(.+), name=(.+)><>(Value|OneMinuteRate)"
  name: "kafka_controller_$1_$2"
# Métricas generales del Server / Broker
- pattern: "kafka.server<type=(.+), name=(.+)><>(Value|OneMinuteRate|MeanRate)"
  name: "kafka_server_$1_$2"
# Métricas de JVM (Memoria, GC, Threads)
- pattern: "java.lang<type=(.+), name=(.+)><>(.+)"
  name: "jvm_$1_$2_$3"
- pattern: "java.lang<type=(.+)><>(.+)"
  name: "jvm_$1_$2"
YAML
  }
}*/



resource "kubectl_manifest" "kafka_pod_monitor" {
  count      = var.enable_kafka ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PodMonitor"
    metadata = {
      name      = "kafka-resources-metrics"
      namespace = kubernetes_namespace.kafka.metadata[0].name
      labels = { release = "kube-prometheus-stack" }
    }
    spec = {
      selector = {
        matchLabels = { "strimzi.io/kind" = "Kafka" }
      }
      podMetricsEndpoints = [
        {
          port     = "tcp-prometheus"
          path     = "/metrics"
          interval = "15s"
          relabelings = [
            {
              sourceLabels = ["__meta_kubernetes_pod_label_strimzi_io_cluster"]
              targetLabel  = "strimzi_io_cluster"
            },
            {
              sourceLabels = ["__meta_kubernetes_pod_name"]
              targetLabel  = "kubernetes_pod_name"
            },
            {
              sourceLabels = ["__meta_kubernetes_pod_name"]
              targetLabel  = "pod_name"
            },
            {
              sourceLabels = ["__meta_kubernetes_pod_label_strimzi_io_name"]
              targetLabel  = "strimzi_io_name"
            }
          ]
        }
      ]
    }
  })
  depends_on = [kubectl_manifest.kafka_cluster[0], helm_release.kube_prometheus_stack]
}

resource "kubectl_manifest" "kafka_exporter_monitor" {
  count      = var.enable_kafka ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PodMonitor"
    metadata = {
      name      = "kafka-exporter-metrics"
      namespace = kubernetes_namespace.kafka.metadata[0].name
      labels = { release = "kube-prometheus-stack" }
    }
    spec = {
      selector = {
        matchLabels = { "strimzi.io/kind" = "KafkaExporter" }
      }
      podMetricsEndpoints = [
        {
          port     = "tcp-prometheus"
          path     = "/metrics"
          interval = "15s"
          relabelings = [
            {
              sourceLabels = ["__meta_kubernetes_pod_label_strimzi_io_cluster"]
              targetLabel  = "strimzi_io_cluster"
            },
            {
              sourceLabels = ["__meta_kubernetes_pod_name"]
              targetLabel  = "kubernetes_pod_name"
            },
            {
              sourceLabels = ["__meta_kubernetes_pod_name"]
              targetLabel  = "pod_name"
            }
          ]
        }
      ]
    }
  })
  depends_on = [kubectl_manifest.kafka_cluster[0], helm_release.kube_prometheus_stack]
}

# 1. Descarga de los JSONs oficiales desde las rutas de packaging/ de Strimzi
# Dashboard de Salud del Clúster, KRaft, I/O y Réplicas
data "http" "strimzi_cluster_json" {
  url = "https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/${var.strimzi_version}/packaging/examples/metrics/grafana-dashboards/strimzi-kafka.json"
  request_headers = { Accept = "application/json" }
}
# Dashboard de Consumer Lag y Grupos de Consumo (Kafka Exporter)
data "http" "strimzi_consumers_json" {
  url = "https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/${var.strimzi_version}/packaging/examples/metrics/grafana-dashboards/strimzi-kafka-exporter.json"
  request_headers = { Accept = "application/json" }
}


# 2. Creas el ConfigMap inyectando el cuerpo descargado (data.http.kafka_dashboard.response_body)
resource "kubernetes_config_map" "grafana_dashboard_kafka_cluster" {
  count      = var.enable_kafka ? 1 : 0
  metadata {
    name      = "grafana-dashboard-kafka-cluster"
    namespace = "monitoring"
    labels = {
      grafana_dashboard = "1"
      release           = "kube-prometheus-stack"
    }
  }
  data = { "strimzi-kafka.json" = data.http.strimzi_cluster_json.response_body }
  depends_on = [helm_release.kube_prometheus_stack]
}

# 2. Creas el ConfigMap inyectando el cuerpo descargado (data.http.kafka_dashboard.response_body)
resource "kubernetes_config_map" "grafana_dashboard_kafka_consumers" {
  count      = var.enable_kafka ? 1 : 0
  metadata {
    name      = "grafana-dashboard-kafka-consumers"
    namespace = "monitoring"
    labels = {
      grafana_dashboard = "1"
      release           = "kube-prometheus-stack"
    }
  }
  data = { "strimzi-kafka-exporter.json" = data.http.strimzi_consumers_json.response_body }
  depends_on = [helm_release.kube_prometheus_stack]
}
