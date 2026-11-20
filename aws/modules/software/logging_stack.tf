
## Loki SimpleScalable requires S3 for storage
# Bucket S3 principal
resource "aws_s3_bucket" "loki_storage" {
  count         = var.enable_monitoring ? 1 : 0
  bucket        = "rj-engineering-${var.environment}-loki-${var.eks.cluster_name}"
  force_destroy = false # Evita borrado accidental de logs en destrucciones involuntarias

  tags = merge(local.common_tags, {
    Name = "rj-engineering-${var.environment}-loki-${var.eks.cluster_name}"
    Role = "loki-storage"
  })
}

# Bloqueo estricto de acceso público (Seguridad / CIS Benchmark)
resource "aws_s3_bucket_public_access_block" "loki_storage" {
  count                   = var.enable_monitoring ? 1 : 0
  bucket                  = aws_s3_bucket.loki_storage[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Cifrado en reposo (SSE-S3 recomendado para Loki)
resource "aws_s3_bucket_server_side_encryption_configuration" "loki_storage" {
  count  = var.enable_monitoring ? 1 : 0
  bucket = aws_s3_bucket.loki_storage[0].id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# Limpieza de subidas multipart fallidas (Control de costes)
resource "aws_s3_bucket_lifecycle_configuration" "loki_storage" {
  count  = var.enable_monitoring ? 1 : 0
  bucket = aws_s3_bucket.loki_storage[0].id
  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"
    filter {} # Aplica la regla a todo el bucket
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}


# Rol IAM para que los Pods de Loki accedan a S3 sin claves fijas
resource "aws_iam_role" "loki_s3" {
  count = var.enable_monitoring ? 1 : 0
  name  = "loki-s3-${var.environment}-${var.eks.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.eks.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.eks.oidc_issuer}:sub" = "system:serviceaccount:monitoring:loki"
          "${var.eks.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# IAM Policy con S3 permissions
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
      Resource = [aws_s3_bucket.loki_storage[0].arn, "${aws_s3_bucket.loki_storage[0].arn}/*"]
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
                sum by (k8s_namespace_name, k8s_pod_name) (rate({k8s_namespace_name=~".+"} |~ "(?i)\\berror\\b" [5m])) > 1
              for: 3m
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
  depends_on = [helm_release.kube_prometheus_stack]
}

# 5. Loki Helm package
# SingleBinary: Monolítico): Todos los componentes de Loki (ingesta, consulta, almacenamiento, compactación y reglas) corren dentro de un único pod,
#   Utiliza EBS para chunks e indices
#   Desventaja: No escala de forma independiente. Si el tráfico de logs sube mucho, ese único pod colapsa de CPU o memoria, y si se reinicia
# SimpleScalable (Distribuido): escalan por separado: write (recibe e ingiere logs), read (atiende las consultas de Grafana) y backend (maneja la compactación, la indexación y el motor de alertas ruler).
#   utiliza S3 como almacenamiento de objetos definitivo.
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

      # Deactivate Helm tests
      test = { enabled = false }
      # Permiter evaluar la latencia o perdidas de logs generando logs y consultando loki para evaluar tiempos o perdidas
      lokiCanary = { enabled = false }
      # Activa un proxy Nginx frontal que unifica el tráfico interno de entrada hacia los microservicios de Loki
      gateway = {
        enabled  = true # false for SingleBinary
        replicas = 1
      }

      # Service Account with s3 access permissions, needed for Simple Scaling mode
      serviceAccount = {
        create = true
        name   = "loki"
        annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.loki_s3[0].arn }
      }

      resultsCache = { enabled = false }
      chunksCache = { enabled = false }

      loki = {
        auth_enabled = false
        commonConfig = { replication_factor = 1 }

        # Compacta logs en S3 y los fusiona en bloques más grandes y eficientes. Esto reduce drásticamente el uso de espacio en S3
        compactor = {
          working_directory = "/var/loki/compactor"
          delete_request_store = "s3"
          compaction_interval = "10m"
          retention_enabled   = true
          retention_delete_delay = "48h"
          retention_delete_worker_count = 15
        }

        # 2. Definir el tiempo de retención por defecto para todos los logs
        limits_config = { retention_period = "48h" } # 7 días (o ej. "720h" para 30 días, "30d")

        # Storage conf for SingleBinary
        #storage = { type = "filesystem" }

        # Storage conf for simple scalable mode
        storage = {
          type = "s3"
          s3 = { region = var.aws_region }
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
            local = { directory = "/var/loki/rules" }
          }
          rule_path = "/tmp/loki/scratch"
          ring = {
            kvstore = { store = "inmemory" } #store = "memberlist"
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
        nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
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
      }


      read = { replicas = 0 }
      write = { replicas = 0 }
      backend = { replicas = 0 }*/

      write = {
        replicas = 1
        persistence = { # búfer interno llamado WAL (Write-Ahead Log). Antes de empaquetar los logs y subirlos a S3
          enabled      = true
          storageClass = "gp3"
          size         = "10Gi"
        }
        nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
        resources = {
          requests = {
            cpu    = "50m"
            memory = "500Mi"
          }
          limits = {
            cpu    = "150m"
            memory = "1000Mi"
          }
        }
      }

      read = {
        replicas     = 1
        nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
        resources = {
          requests = {
            cpu    = "50m"
            memory = "128Mi"
          }
          limits = {
            cpu    = "150m"
            memory = "256Mi"
          }
        }
      }

      # Funciones backend: compactacion, evaluacion de alertas
      backend = {
        replicas = 1
        persistence = {
          enabled      = true
          storageClass = "gp3"
          size         = "10Gi"
        }
        nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
        resources = {
          requests = {
            cpu    = "50m"
            memory = "256Mi"
          }
          limits = {
            cpu    = "150m"
            memory = "512Mi"
          }
        }
        extraVolumes = [
          {
            name = "loki-rules"
            configMap = { name = "loki-alerting-rules" }
          }
        ]
        # Espacio de disco temporal (scratch space) para procesar los índices y espacio de trabajo donde cargar esas reglas de evaluación
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

  depends_on = [helm_release.kube_prometheus_stack, kubernetes_config_map.loki_rules, kubectl_manifest.karpenter_node_pool_infra]
}


# Despliega un colector DaemonSet que recopila automáticamente los logs del sistema y contenedores (filelog) y trazas OTLP,
# reenviándolos mediante el protocolo HTTP a la puerta de enlace de Loki (loki-gateway) y a Tempo.
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
      mode = "daemonset"
      priorityClassName = "system-node-critical"

      resources = {
        requests = {
          cpu    = "100m"
          memory = "150Mi"
        }
        limits = {
          cpu    = "200m"
          memory = "300Mi"
        }
      }
      # For Log Metadata Enrichment, Query pods, namespaces, nodes y replicasets ... y Correlación de contenedores en los nodos
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
      service = { enabled = true }
      # AUTOMATIZAR EL MONTAJE DE /var/log DEL HOST EN LOS PODS
      presets = {
        logsCollection = {
          enabled = true
          includeCollectorLogs = false
        }
        kubernetesAttributes = {
          enabled = true
        }
      }

      config = {
        receivers = {
          otlp = { # Receive traces from instrumetations
            protocols = { # OTLP estándar tanto en su variante gRPC (puerto 4317) como HTTP (puerto 4318).
              grpc = { endpoint = "0.0.0.0:4317" }
              http = { endpoint = "0.0.0.0:4318" }
            }
          }
          # No required presets alrady includes all logs
          #filelog = {
          #  include = [ "/var/log/pods/*/*/*.log" ]
          #  #exclude = [ "/var/log/pods/monitoring_*/*/*.log" ]
          #}
        }
        processors = { # Procesadores de logs
          batch = {} # Agrupa los registros en lotes para optimizar el envío por la red
          k8sattributes = {} # Enriquece las trazas y logs con información del pod y namespace de origen
        }
        exporters = {
          otlphttp = {
            endpoint =  "http://loki-gateway.monitoring.svc:80/otlp" #"http://loki.monitoring.svc:3100/otlp"
            tls = { insecure = true }
          }
          "otlp/tempo" = {
            endpoint = "tempo.monitoring.svc.cluster.local:4317"
            tls      = { insecure = true }
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
              exporters = ["otlp/tempo"] # Replace with Tempo/Jaeger exporter endpoint
            }
          }
        }
      }
    })
  ]
  depends_on = [helm_release.loki]
}

# 2. Despliegue del OpenTelemetry Operator
# Inyección Automática de Instrumentación (Auto-Instrumentation) via Mutating Admission Webhook
# Gestión y Ciclo de Vida de los Colectores OpenTelemetryCollector (Collector Reconciliation) (No aplica en nuestro caso)
# Inyección de Contexto y Estandarización de Propagadores (Se asegura de que todas las aplicaciones inyectadas utilicen los mismos estándares de propagación de contexto de red (tracecontext, baggage y b3)
resource "helm_release" "otel_operator" {
  count            = var.enable_monitoring ? 1 : 0
  name             = "opentelemetry-operator"
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-operator"
  version          = "0.78.0"
  namespace        = "monitoring"
  create_namespace = false

  values = [
    jsonencode({
      manager = {
        collectorImage = { repository = "otel/opentelemetry-collector-contrib" }
      }
      manager = {
        collectorImage = {
          repository = "otel/opentelemetry-collector-contrib"
        }
        resources = {
          requests = {
            cpu    = "50m"
            memory = "64Mi"
          }
          limits = {
            cpu    = "100m"
            memory = "128Mi"
          }
        }
      }
    })
  ]
  depends_on = [helm_release.cert_manager, helm_release.kube_prometheus_stack]
}

# 3. Configuración del recurso Instrumentation (Auto-instrumentación)
resource "kubectl_manifest" "otel_instrumentation" {
  count           = var.enable_monitoring ? 1 : 0
  validate_schema = false
  yaml_body = yamlencode({

    apiVersion = "opentelemetry.io/v1alpha1"
    kind       = "Instrumentation"
    metadata = {
      name      = "autoinstrumentation"
      namespace = "monitoring"
    }
    spec = {
      # Apunta al colector daemonset existente en tu clúster (como daemonsSet se dirigen a la repica del mismo nodo)
      exporter = { endpoint = "http://opentelemetry-collector.monitoring.svc:4318" }
      propagators = [
        "tracecontext", # W3C Trace Context (standard: traceparent) para pasar el trace_id y span_id
        "baggage",      # propagar metadatos o pares clave-valor personalizados a lo largo de toda la cadena de llamadas
        "b3"            # B3 propagation (Zipkin/Istio compatibility)
      ]
      sampler = { type = "always_on" }

      python = {
        resource = {
          requests = {
            cpu    = "50m"
            memory = "64Mi"
          }
          limits = {
            cpu    = "100m"
            memory = "128Mi"
          }
        }
        env = [
          { name = "OTEL_PYTHON_LOG_CORRELATION", value = "true" },
          #{ name = "OTEL_PYTHON_LOG_FORMAT", value = "%(asctime)s %(levelname)s [%(name)s] [trace_id=%(otelTraceID)032x span_id=%(otelSpanID)016x] - %(message)s" },
          { name = "OTEL_PYTHON_LOG_FORMAT", value = "%(asctime)s %(levelname)s [%(name)s] [%(filename)s:%(lineno)d] [trace_id=%(otelTraceID)s span_id=%(otelSpanID)s] - %(message)s" },
          { name = "OTEL_METRICS_EXPORTER", value = "none" }
        ]
      }

      java = {
        resources = {
          requests = {
            cpu    = "50m"
            memory = "64Mi"
          }
          limits = {
            cpu    = "100m"
            memory = "128Mi"
          }
        }
        env = [
          # configuración de bussines app logs (logback-spring.xml): <property name="CONSOLE_LOG_PATTERN" value="%d{yyyy-MM-dd HH:mm:ss.SSS} [%thread] %-5level %logger{36} [trace_id=%X{trace_id} span_id=%X{span_id}] - %msg%n"/>
          { name = "OTEL_METRICS_EXPORTER", value = "otlp" }, # none for no export
          { name = "OTEL_METRIC_EXPORT_INTERVAL", value = "10000" },  # every 10 seconds
          { name = "OTEL_JAVAAGENT_ENABLED", value = "true" }, # Forzar la inyección de trazas en los logs de Java, Asegurar la correlación de logs y trazas (similar a Python)
          { name  = "OTEL_LOGS_EXPORTER", value = "otlp" }, # El agente de Java inyecta automáticamente %X{trace_id} y %X{span_id} en el MDC de Logback/Log4j2
          { name  = "OTEL_SERVICE_NAME", value = "spring-boot-app" } # Configuración opcional para asegurar que el formato de salida imprima las variables del MDC si tu patrón por defecto no las incluye
        ]
      }

      nodejs = {
        resources = {
          requests = {
            cpu    = "50m"
            memory = "64Mi"
          }
          limits = {
            cpu    = "100m"
            memory = "128Mi"
          }
        }
        env = [{ name = "OTEL_METRICS_EXPORTER", value = "none" } ]
      }
    }
  })

  depends_on = [helm_release.otel_operator]
}
