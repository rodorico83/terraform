
## Loki SimpleScalable requires S3 for storage
# 1. Bucket S3 para guardar los logs
resource "aws_s3_bucket" "loki_storage" {
  count         = var.enable_monitoring ? 1 : 0
  bucket        = "rj-engineering-${var.environment}-loki-${var.eks.cluster_name}"
  force_destroy = false
}

# 2. Rol IAM para que los Pods de Loki accedan a S3 sin claves fijas
resource "aws_iam_role" "loki_s3" {
  count = var.enable_monitoring ? 1 : 0
  name  = "loki-s3-access-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.eks.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(var.eks.oidc_provider_url, "https://", "")}:sub" = "system:serviceaccount:monitoring:loki"
          "${replace(var.eks.oidc_provider_url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# 3. IAM Policy con S3 permissions
resource "aws_iam_role_policy" "loki_s3" {
  count = var.enable_monitoring ? 1 : 0
  role  = aws_iam_role.loki_s3[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:ListBucket",
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject"
      ]
      Resource = [
        aws_s3_bucket.loki_storage[0].arn,
        "${aws_s3_bucket.loki_storage[0].arn}/*"
      ]
    }]
  })
}

# 4. Loki Rules in config_map
resource "kubernetes_config_map" "loki_rules" {
  count = var.enable_monitoring ? 1 : 0
  metadata {
    name      = "loki-alerting-rules"
    namespace = "monitoring"
  }
  data = {
    "alerts.yaml" = <<-YAML
      groups:
        - name: alertas-logs-loki
          interval: 1m
          rules:
            - alert: LogContainsErrorPattern
              expr: |
                sum by (k8s_namespace_name, k8s_pod_name) (rate({k8s_namespace_name=~".+"} |~ "(?i)error" [5m])) > 0
              for: 0m
              labels:
                severity: warning
                namespace: "{{ $labels.k8s_namespace_name }}"
                pod: "{{ $labels.k8s_pod_name }}"
              annotations:
                summary: "Errores detectados en logs del Pod {{ $labels.k8s_pod_name }} Namespace {{ $labels.k8s_namespace_name }}"
                description: "El Pod {{ $labels.k8s_namespace_name }}:{{ $labels.k8s_pod_name }} ha emitido mensajes de error en los últimos minutos."
                grafana_url: 'https://grafana.aws.rj-engineering.com/explore?left=%5B%22now-1h%22%2C%22now%22%2C%22loki%22%2C%7B%22expr%22%3A%22%7Bk8s_namespace_name%3D%5C%22{{ $labels.k8s_namespace_name }}%5C%22%2Ck8s_pod_name%3D%5C%22{{ $labels.k8s_pod_name }}%5C%22%7D%20%7C~%20%5C%22%28%3Fi%29error%5C%22%22%7D%5D'
    YAML
  }
}

# 5. Loki Helm package
resource "helm_release" "loki" {
  count            = var.enable_monitoring ? 1 : 0
  name             = "loki"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki"
  version          = "6.6.0" # Monolithic/Simple-scalable mode
  namespace        = "monitoring"
  create_namespace = false

  values = [
    jsonencode({
      deploymentMode = "SimpleScalable" #"SingleBinary"

      # 1. DESACTIVAR LOS TESTS DE HELM PARA EVITAR EL ERROR DE VALIDACIÓN
      test = { enabled = false }
      # 2. DESACTIVAR LOKI-CANARY (Sintaxis oficial Chart v6)
      lokiCanary = { enabled = false }
      # DESACTIVAR GATEWAY Y CACHES INNECESARIOS EN SINGLE BINARY
      #gateway = { enabled = false }
      gateway = {
        enabled  = true # false for SingleBinary
        replicas = 1
      }

      # Service Account with s3 access permissions, needed for Simple Scaling mode
      serviceAccount = {
        create = true
        name   = "loki"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.loki_s3[0].arn
        }
      }

      resultsCache = { enabled = false }
      chunksCache = { enabled = false }

      loki = {
        auth_enabled = false
        commonConfig = { replication_factor = 1 }

        compactor = {
          working_directory = "/var/loki/compactor"
          delete_request_store          = "s3"
          compaction_interval = "10m"
          retention_enabled   = true
          retention_delete_delay = "2h"
          retention_delete_worker_count = 15
        }

        # 2. Definir el tiempo de retención por defecto para todos los logs
        limits_config = {
          retention_period = "48h" # 7 días (o ej. "720h" para 30 días, "30d")
        }

        # Storage conf for SingleBinary
        #storage = { type = "filesystem" }
        # Storage conf for simple scalable mode
        storage = {
          type = "s3"
          s3 = {
            region = var.aws_region # Tu región de AWS
          }
          bucketNames = {
            chunks = aws_s3_bucket.loki_storage[0].bucket
            ruler  = aws_s3_bucket.loki_storage[0].bucket
            admin  = aws_s3_bucket.loki_storage[0].bucket
          }
        }


        rulerConfig = {
          alertmanager_url  = "http://kube-prometheus-stack-alertmanager.monitoring.svc:9093"
          enable_alertmanager_v2 = true
          storage = {
            type  = "local"
            local = {
              directory = "/var/loki/rules"
            }
          }
          rule_path = "/tmp/loki/scratch"
          ring = {
            kvstore = {
              #store = "memberlist"
              store = "inmemory"
            }
          }
        }

        schemaConfig = {
          configs = [
            {
              from         = "2024-04-01"
              store        = "tsdb"
              #object_store = "filesystem" # Single Binary EBS
              object_store = "s3"
              schema       = "v13"
              index = {
                prefix = "index_"
                period = "24h"
              }
            }
          ]
        }

      }

      # Single binary deactivated
      singleBinary = {
        replicas = 0
        /*persistence = {
          enabled      = true
          storageClass = "gp3"
          size         = "10Gi"
        }
        nodeSelector = { "karpenter.sh/capacity-type" = "spot" }
        extraVolumes = [
          {
            name = "loki-rules"
            configMap = { name = "loki-alerting-rules" }
          }
        ]
        extraVolumeMounts = [
          {
            name      = "loki-rules"
            mountPath = "/var/loki/rules/fake"
            readOnly  = true
          }
        ]*/
      }

      # Nota: Cuando usas ruler.directories dentro de Helm, Helm también crea un ConfigMap por debajo (llamado loki-ruler-fake).
      # El problema es que el chart oficial de Loki tiene un fallo conocido en modo SingleBinary: crea el ConfigMap pero olvida montarlo dentro del pod loki-0, provocando el crash de mkdir: read-only file system. Por eso declararlo tú mismo en Terraform es la solución estándar y 100% fiable.
      # Activación del Ruler y Definición de la Alerta LogQL
      /*ruler = {
        enabled = true
        directories = {
          fake = { # "fake" es el namespace interno cuando auth_enabled = false
            "alerts.yaml" = <<-YAML
              ...
            YAML
          }
        }
      }*/

      /* DESACTIVAR EXPLÍCITAMENTE LOS COMPONENTES DE SIMPLE SCALABLE
      read = { replicas = 0 }
      write = { replicas = 0 }
      backend = { replicas = 0 }*/

      write = {
        replicas = 1
        persistence = {
          enabled      = true
          storageClass = "gp3"
          size         = "10Gi"
        }
        nodeSelector = { "karpenter.sh/capacity-type" = "spot" }
      }

      read = {
        replicas     = 1
        nodeSelector = { "karpenter.sh/capacity-type" = "spot" }
      }

      backend = {
        replicas = 1
        persistence = {
          enabled      = true
          storageClass = "gp3"
          size         = "10Gi"
        }
        nodeSelector = { "karpenter.sh/capacity-type" = "spot" }
        extraVolumes = [
          {
            name = "loki-rules"
            configMap = { name = "loki-alerting-rules" }
          }
        ]
        extraVolumeMounts = [
          {
            name      = "loki-rules"
            mountPath = "/var/loki/rules/fake"
            readOnly  = true
          }
        ]

      }
    })
  ]

  depends_on = [helm_release.kube_prometheus_stack, kubernetes_config_map.loki_rules]
}

resource "helm_release" "otel_collector" {
  count            = var.enable_monitoring ? 1 : 0
  name             = "opentelemetry-collector"
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-collector"
  version          = "0.85.0"
  namespace        = "monitoring"
  create_namespace = false

  values = [
    jsonencode({
      mode = "daemonset" # Collects node-level logs/traces or acts as agent
      priorityClassName = "system-node-critical"
      clusterRole = {
        create = true
        name   = "opentelemetry-collector-cluster-role"
        rules = [
          {
            apiGroups = [""]
            resources = ["pods", "namespaces", "nodes"]
            verbs     = ["get", "list", "watch"]
          },
          {
            apiGroups = ["apps"]
            resources = ["replicasets"]
            verbs     = ["get", "list", "watch"]
          }
        ]
      }
      # AUTOMATIZAR EL MONTAJE DE /var/log DEL HOST EN LOS PODS
      presets = {
        logsCollection = {
          enabled = true
          includeCollectorLogs = false
        }
      }

      config = {
        receivers = {
          otlp = {
            protocols = {
              grpc = { endpoint = "0.0.0.0:4317" }
              http = { endpoint = "0.0.0.0:4318" }
            }
          }
          filelog = {
            include = [ "/var/log/pods/*/*/*.log" ]
            #exclude = [ "/var/log/pods/monitoring_*/*/*.log" ]
          }
        }
        processors = {
          batch = {}
          k8sattributes = {}
        }
        exporters = {
          otlphttp = {
            endpoint =  "http://loki-gateway.monitoring.svc:80/otlp" #"http://loki.monitoring.svc:3100/otlp"
            tls = { insecure = true }
          }
          debug = { verbosity = "basic" }
        }
        service = {
          pipelines = {
            logs = {
              receivers = ["otlp", "filelog"]
              processors = ["k8sattributes", "batch"]
              exporters = ["otlphttp"]
            }
            traces = {
              receivers = ["otlp"]
              processors = ["batch"]
              exporters = ["debug"] # Replace with Tempo/Jaeger exporter endpoint
            }
          }
        }
      }
    })
  ]
  depends_on = [helm_release.loki]
}