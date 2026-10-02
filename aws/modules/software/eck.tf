# ==============================================================================
# 1. NAMESPACE Y OPERADOR ECK (ELASTIC CLOUD ON KUBERNETES)
# ==============================================================================
resource "kubernetes_namespace" "logging" {
  metadata {
    name = "logging"
  }
}

# Instalación del operador oficial ECK
resource "helm_release" "elastic_operator" {
  count       = var.enable_eck  ? 1 : 0
  name       = "elastic-operator"
  repository = "https://helm.elastic.co"
  chart      = "eck-operator"
  version    = "3.5.0" # Última versión estable del operador ECK de Elastic
  namespace  = kubernetes_namespace.logging.metadata[0].name
}

# ==============================================================================
# 2. ALMACENAMIENTO: ELASTICSEARCH Y KIBANA (USANDO KUBECTL_MANIFEST)
# ==============================================================================
resource "kubectl_manifest" "elasticsearch" {
  count       = var.enable_eck  ? 1 : 0
  depends_on = [helm_release.elastic_operator]

  # ¡AHORA SÍ! Este proveedor sí reconoce y procesa estos argumentos
  validate_schema = false
  #force_new       = true

  yaml_body = yamlencode({
    apiVersion = "elasticsearch.k8s.elastic.co/v1"
    kind       = "Elasticsearch"
    metadata = {
      name      = "elasticsearch"
      namespace = kubernetes_namespace.logging.metadata[0].name
    }
    spec = {

      version = "8.12.2"

      nodeSets = [{
        name  = "default"
        count = 1
        config = {
          "node.roles" = ["master", "data", "data_content", "data_hot"]
        }
        podTemplate = {
          spec = {
            nodeSelector = { "karpenter.sh/capacity-type" = "spot" }
            containers = [{
              name = "elasticsearch"
              env = [
                {
                  name  = "ES_JAVA_OPTS"
                  value = "-Xms2g -Xmx2g" # Java
                }
              ]
              resources = {
                limits   = { memory = "3Gi", cpu = "2" }
                requests = { memory = "2Gi", cpu = "1" }
              }
            }]
          }
        }
        volumeClaimTemplates = [{
          metadata = { name = "elasticsearch-data" }
          spec = {
            accessModes      = ["ReadWriteOnce"]
            storageClassName = "gp3"
            resources        = { requests = { storage = "10Gi" } }
          }
        }]
      }]
    }
  })
}

resource "kubectl_manifest" "kibana" {
  count       = var.enable_eck  ? 1 : 0
  depends_on = [kubectl_manifest.elasticsearch]

  # Aplicamos lo mismo para Kibana
  validate_schema = false
  #force_new       = true

  yaml_body = yamlencode({
    apiVersion = "kibana.k8s.elastic.co/v1"
    kind       = "Kibana"
    metadata = {
      name      = "kibana"
      namespace = kubernetes_namespace.logging.metadata[0].name
    }
    spec = {
      version = "8.12.2"
      count   = 1
      elasticsearchRef = {
        # Corregido para que apunte dinámicamente al nombre real de arriba
        name = "elasticsearch"
      }
      podTemplate = {
        spec = {
          nodeSelector = { "karpenter.sh/capacity-type" = "spot" }
        }
      }
    }
  })
}

# ==============================================================================
# 6. CONFIGURACIÓN DEL INGRESS PARA NGINX CONTROLLER (SSL TERMINATION)
# ==============================================================================
resource "kubernetes_ingress_v1" "kibana_ingress" {
  count       = var.enable_eck  ? 1 : 0
  depends_on = [kubectl_manifest.kibana]

  metadata {
    name      = "kibana-ingress"
    namespace = kubernetes_namespace.logging.metadata[0].name

    annotations = {
      # Identifica tu controlador NGINX
      "kubernetes.io/ingress.class" = "nginx"
      "cert-manager.io/cluster-issuer"  = "letsencrypt-${var.environment}"
      # OBLIGATORIO: Kibana (dentro del pod) sigue hablando HTTPS internamente.
      # NGINX termina el SSL externo, pero inicia un TLS interno hacia el Pod de Kibana.
      "nginx.ingress.kubernetes.io/backend-protocol" = "HTTPS"
      # Redirección automática de HTTP a HTTPS (Buenas prácticas)
      "nginx.ingress.kubernetes.io/ssl-redirect" = "true"
      # Optimización de tiempos de espera para consultas analíticas pesadas
      "nginx.ingress.kubernetes.io/proxy-connect-timeout" = "60"
      "nginx.ingress.kubernetes.io/proxy-read-timeout"    = "600"
      "nginx.ingress.kubernetes.io/proxy-send-timeout"    = "600"
      "nginx.ingress.kubernetes.io/proxy-body-size"       = "50m"
    }
  }
  spec {
    ingress_class_name = "nginx"
    rule {
      host = "kibana.aws.rj-engineering.com" # <--- REEMPLAZA CON TU DOMINIO REAL
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              # Servicio HTTPS autogenerado por el operador ECK
              name = "kibana-kb-http"
              port {
                number = 5601
              }
            }
          }
        }
      }
    }
    # 🔒 Bloque TLS para que Cert-Manager genere y asocie el certificado en tu NLB
    tls {
      hosts       = ["kibana.aws.rj-engineering.com"]
      secret_name = "kibana-server-tls" # Cert-Manager creará este secreto con el certificado válido
    }
  }
}


# ==============================================================================
# 3. INTERMEDIARIO: LOGSTASH DESPLEGADO POR EL PROPIO OPERADOR ECK (NATIVO)
# ==============================================================================
# Eliminamos helm_release para Logstash. Usamos el operador nativo para evitar fallos de repositorios.
resource "kubectl_manifest" "logstash" {
  count       = var.enable_eck  ? 1 : 0
  depends_on      = [kubectl_manifest.elasticsearch]
  validate_schema = false
  #force_new       = true

  yaml_body = yamlencode({
    apiVersion = "logstash.k8s.elastic.co/v1alpha1"
    kind       = "Logstash"
    metadata = {
      name      = "logstash"
      namespace = kubernetes_namespace.logging.metadata[0].name
    }

    spec = {
      version = "8.12.2"
      count   = 1

      # Inyección automática de la pipeline en la sintaxis nativa de Elastic
      pipelines = [{
        "pipeline.id" = "main"
        "config.string" = <<-EOT
          input {
            http {
              port => 24224
              additional_codecs => { "application/x-ndjson" => "json" }
              ssl => false
              #ssl_certificate => "/usr/share/logstash/config/certs/tls.crt"
              #ssl_key => "/usr/share/logstash/config/certs/tls.key"
            }
          }
          filter {
            # 1. Parsea la cadena JSON completa enviada por Fluent Bit en 'message' u 'event.original'
            json {
              source => "message"
            }

            # 2. Si venía en event.original en lugar de message, intentamos parsearlo también por respaldo
            if ![kubernetes] {
              json {
                source => "event.original"
              }
            }

            if [kubernetes][container_name] == "db-connectivity-tester" {
              json {
                source => "log"
                target => "app"
              }
            }
            date {
              match => [ "[kubernetes][time]", "ISO8601" ]
              target => "@timestamp"
            }
          }
          output {
            elasticsearch {
              hosts => ["https://elasticsearch-es-http.logging.svc.cluster.local:9200"]
              index => "eks-direct-logs-%%{+YYYY.MM.dd}"
              user  => "elastic"
              password => "$${ELASTICSEARCH_PASSWORD}"
              ssl => true
              ssl_certificate_verification => false
            }
          }
        EOT
      }]

      services = [
        {
          name = "input-http"
          service = {
            spec = {
              type = "ClusterIP"
              ports = [{
                name       = "log-http"
                port       = 24224
                targetPort = 24224
                protocol   = "TCP"
              }]
            }
          }
        }
      ]

      # El operador ECK mapea de forma segura las variables de entorno de esta manera
      podTemplate = {
        spec = {
          nodeSelector = { "karpenter.sh/capacity-type" = "spot" }
          tolerations = [
            { key = "nas-system-nodes", operator = "Exists", effect = "NoSchedule" }
          ]
          containers = [{
            name = "logstash"

            # Evita el fallo de TLS/HTTPS en el puerto 9600 evaluando solo la apertura de socket
            readinessProbe = {
              tcpSocket = {
                port = 9600
              }
              initialDelaySeconds = 30
              periodSeconds       = 10
              timeoutSeconds      = 5
              failureThreshold    = 3
            }

            livenessProbe = {
              tcpSocket = {
                port = 9600
              }
              initialDelaySeconds = 60
              periodSeconds       = 20
              timeoutSeconds      = 5
              failureThreshold    = 5
            }

            env = [{
              name = "ELASTICSEARCH_PASSWORD"
              valueFrom = {
                secretKeyRef = {
                  name = "elasticsearch-es-elastic-user"
                  key  = "elastic"
                }
              }
            }]
          }]
        }
      }
    }
  })
}

/*resource "helm_release" "logstash" {
  depends_on = [kubectl_manifest.elasticsearch]

  name       = "logstash"
  repository = "oci://registry-1.docker.io/bitnamicharts" # # FIX: Cambiado al repositorio activo de Bitnami
  chart      = "logstash"
  version    = "6.1.3" # Versión estable del chart de Bitnami (instala internamente Logstash 8.x)
  namespace  = kubernetes_namespace.logging.metadata[0].name

  values = [
    yamlencode({
      # Habilitamos un Service de K8s para que Fluent Bit envíe datos aquí internamente
      service = {
        type = "ClusterIP"
        ports = [
          {
            name       = "fluent-forward"
            port       = 24224
            protocol   = "TCP"
            targetPort = 24224
          }
        ]
      }

      logstashPipeline = {
        "logstash.conf" = <<-EOT
          input {
            # Recibe el flujo continuo de logs directamente de Fluent Bit por TCP
            forward {
              port => 24224
              bind => "0.0.0.0"
            }
          }

          filter {
            # --- TUS REGLAS DE FILTRADO AQUÍ ---
            # Ejemplo: Si tus aplicaciones imprimen JSON, puedes parsearlo:
            if [kubernetes][container_name] == "mi-app-backend" {
              json {
                source => "log"
                target => "app"
              }
            }

            date {
              match => [ "[kubernetes][time]", "ISO8601" ]
              target => "@timestamp"
            }
          }

          output {
            elasticsearch {
              # DNS interno TLS mutuo gestionado por el operador ECK
              hosts => ["https://cluster.local"]
              index => "eks-direct-logs-%%{+YYYY.MM.dd}"
              user  => "elastic"
              password => "$${ELASTICSEARCH_PASSWORD}"
              ssl => true
              ssl_certificate_verification => false # El operador usa certificados autofirmados internos
            }
          }
        EOT
      }

      # Vinculación segura de credenciales sin hardcodear contraseñas
      extraEnvs = [{
        name = "ELASTICSEARCH_PASSWORD"
        valueFrom = {
          secretKeyRef = {
            name = "elasticsearch-prod-es-elastic-user"
            key  = "elastic"
          }
        }
      }]
    })
  ]
}*/

# ==============================================================================
# 4. RECOLECTOR (LOG SHIPPER): FLUENT BIT (ENVÍO DIRECTO A LOGSTASH)
# ==============================================================================
resource "helm_release" "fluent_bit" {
  count       = var.enable_eck  ? 1 : 0
  depends_on = [kubectl_manifest.logstash]

  name       = "fluent-bit"
  repository = "https://fluent.github.io/helm-charts"
  chart      = "fluent-bit"
  version    = "0.47.0" # Última versión compatible con pipelines modernos v3.x/5.x
  namespace  = kubernetes_namespace.logging.metadata[0].name

  values = [
    yamlencode({

      # disable Liveness/Readiness Probes.
      httpServer = false
      livenessProbe  = null
      readinessProbe = null
      env = [
        { name = "HTTP_Listen", value = "0.0.0.0" },
        { name = "HTTP_Port", value = "2020" }
      ]

      config = {

        # Activamos el servidor HTTP interno en el puerto 2020
        # para que las Probes de Kubernetes no maten el contenedor.
        /*service = format(<<-EOT
          [SERVICE]
              Flush         1
              Log_Level     info
              Parsers_File  parsers.conf
              HTTP_Server   On
              HTTP_Port     2020
        EOT
        )*/

        inputs = <<-EOT
          [INPUT]
              Name              tail
              Tag               kube.*
              Path              /var/log/containers/*.log
              Exclude_Path      /var/log/containers/*_monitoring_*.log, /var/log/containers/*_kube-system_*.log, /var/log/containers/*_ingress-nginx_*.log
              Parser            docker
              DB                /var/log/flb_kube_v2.db
              Mem_Buf_Limit     5MB
              Skip_Long_Lines   On
        EOT

        filters = <<-EOT
          [FILTER]
              Name                kubernetes
              Match               kube.*
              Kube_URL            https://kubernetes.default.svc
              Kube_CA_File        /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
              Kube_Token_File     /var/run/secrets/kubernetes.io/serviceaccount/token
              Kube_Tag_Prefix     kube.var.log.containers.
              Merge_Log           On
              Keep_Log            Off
        EOT

        # REDIRECCIÓN SIN KAFKA: Se usa el plugin 'forward' hacia el DNS interno de Logstash
        outputs = <<-EOT
          [OUTPUT]
              Name            http
              Match           kube.*
              # El operador ECK nombra el servicio de la siguiente forma: [Nombre-Recurso]-ls-http
              Host            logstash-ls-input-http.logging.svc.cluster.local
              Port            24224
              # Configuración TLS requerida por la seguridad por defecto de ECK
              tls             Off
              #tls.verify      Off
              Retry_Limit     False
        EOT
      }
    })
  ]
}
