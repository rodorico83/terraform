# ==============================================================================
# 1.1 CAPA DE SEGURIDAD (PERMISOS IAM PARA QUE GRAFANA LEA AWS CLOUDWATCH)
# ==============================================================================
resource "aws_iam_role" "grafana_aws_reader" {
  count       = var.enable_monitoring  ? 1 : 0
  name        = "grafana-iam-role"
  description = "Rol IAM para que Grafana lea metricas de hardware de RDS y VPN en AWS"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.eks.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          # OJO: la condicion IRSA se construye sobre el emisor OIDC del cluster,
          # NO sobre el endpoint del API server: son hostnames distintos.
          # Restringimos el rol estrictamente a la ServiceAccount de Grafana.
          "${local.oidc_issuer_host}:sub" = "system:serviceaccount:monitoring:kube-prometheus-stack-grafana"
          "${local.oidc_issuer_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "grafana_cloudwatch_readonly" {
  count       = var.enable_monitoring  ? 1 : 0
  role       = aws_iam_role.grafana_aws_reader[0].name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}


# ==============================================================================
# 2. CREDENCIAL DE ADMINISTRACION DE GRAFANA
# ==============================================================================
# Generada, no escrita en el repositorio. Sigue quedando en el state de
# Terraform, asi que el state debe estar cifrado (ya lo esta) y con acceso
# restringido.
resource "random_password" "grafana_admin" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "grafana_admin" {
  count       = var.enable_monitoring  ? 1 : 0
  name        = "${var.environment}/grafana/admin-password"
  recovery_window_in_days = 0 # 👈 Fuerza borrado inmediato si Terraform lo destruye
  description = "Grafana admin password for the kube-prometheus-stack release"
  tags        = local.common_tags
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  count       = var.enable_monitoring  ? 1 : 0
  secret_id     = aws_secretsmanager_secret.grafana_admin[0].id
  secret_string = random_password.grafana_admin.result
}

# ==============================================================================
# 3. INSTALACION AUTOMATIZADA DE LA SUITE DE OBSERVABILIDAD VIA HELM
# ==============================================================================

# Adjuntar la política oficial administrada por AWS para controladores EBS
/*resource "aws_iam_role_policy_attachment" "ebs_csi_policy" {
  count      = var.environment == "prod" ? 1 : 0
  role       = var.storage.ebs_csi_driver_rol_name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}*/


resource "helm_release" "kube_prometheus_stack" {
  count       = var.enable_monitoring  ? 1 : 0
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "56.6.2"
  namespace        = "monitoring"
  create_namespace = true

  # --- INYECCION DE VALUES AVANZADOS MEDIANTE JSONENCODE ---
  values = [
    jsonencode({

      # 1 Create automatically the correct read cluster role for the service
      global = { rbac = { create = true } }

      # A) Configuracion Avanzada de Grafana
      grafana = {
        enabled = true
        adminPassword = random_password.grafana_admin.result
        #nodeSelector = { "eks.amazonaws.com/nodegroup" = "private-workers" }
        nodeSelector = { "karpenter.sh/capacity-type" = "spot" }
        serviceAccount = {
          create = true
          annotations = {
            # Clave de anotacion IRSA exacta que exige el webhook de EKS.
            "eks.amazonaws.com/role-arn" = aws_iam_role.grafana_aws_reader[0].arn
          }
        }

        ingress = {
          enabled          = true
          ingressClassName = "nginx" # Apunta a nuestro Ingress Controller
          # Enrutamiento por subdominio
          hosts            = ["grafana.aws.rj-engineering.com"]
          paths            = ["/"]

          annotations = {
            "cert-manager.io/cluster-issuer"               = "letsencrypt-${var.environment}"
            "nginx.ingress.kubernetes.io/backend-protocol" = "HTTP"
            "nginx.ingress.kubernetes.io/ssl-redirect" = "true"
          }

          tls = [
            {
              hosts      = ["grafana.aws.rj-engineering.com"]
              secretName = "grafana-server-tls-secret"
            }
          ]
        }

        # 🎯 Conectar la interfaz de Grafana con la API de Alertmanager
        alertmanager = {
          enabled = true
          # URL interna del servicio Kubernetes de Alertmanager en el namespace 'monitoring'
          url = "http://kube-prometheus-stack-alertmanager.monitoring.svc:9093"
        }

        # 🎯 Registrar Alertmanager como Data Source nativo en Grafana
        additionalDataSources = [
          {
            name      = "Alertmanager"
            type      = "alertmanager"
            uid       = "alertmanager"
            url       = "http://kube-prometheus-stack-alertmanager.monitoring.svc:9093"
            access    = "proxy"
            jsonData  = {
              implementation = "prometheus"
            }
          },
          {
            name      = "Loki"
            type      = "loki"
            uid       = "loki"
            url       = "http://loki-gateway.monitoring.svc:80"   #"http://loki.monitoring.svc:3100"
            access    = "proxy"
            jsonData  = {
              maxLines = 1000
            }
          }
        ]

        # IMPORTACIÓN AUTOMÁTICA DE DASHBOARDS DE LA COMUNIDAD (GitOps)
        dashboardProviders = {
          "dashboardproviders.yaml" = {
            apiVersion = 1
            providers = [
              {
                name            = "default"
                orgId           = 1
                folder          = "Infraestructure"
                type            = "file"
                disableDeletion = false
                editable        = true
                options = {
                  path = "/var/lib/grafana/dashboards/default"
                }
              }
            ]
          }
        }

        dashboards = {
          default = {
            # Descarga e instala automáticamente el Dashboard oficial de Ingress-NGINX (ID: 9614)
            ingress-nginx = {
              gnetId     = 9614
              revision   = 1
              datasource = "Prometheus"
            }
            # 2. Dashboard comunitario de Argo CD (ID: 14584)
            argocd-overview = {
              gnetId     = 14584
              revision   = 1
              datasource = "Prometheus"
            }
            argocd-app-status = {
              gnetId     = 12000
              revision   = 1
              datasource = "Prometheus"
            }
            kubecost-cluster = {
              gnetId     = 15132
              revision   = 1
              datasource = "Prometheus"
            }
            kubecost-namespace = {
              gnetId     = 15133
              revision   = 1
              datasource = "Prometheus"
            }
          }
        }
      }

      # 2 Configuracion del Almacenamiento Persistente de Prometheus
      # Evita que las metricas se borren si las instancias EC2 Spot se reinician.
      # Requiere el addon aws-ebs-csi-driver y una StorageClass gp3 (ver README).
        prometheus = {
        prometheusSpec = {

          # 🎯 DESACTIVAR FILTROS DE ETIQUETAS Y NAMESPACES PARA REGLAS
          # Permite que Prometheus lea CUALQUIER PrometheusRule creada en el clúster
          ruleNamespaceSelector = {}
          ruleSelectorNilUsesHelmValues = false

          # Permite buscar ServiceMonitors en cualquier namespace del clúster
          serviceMonitorNamespaceSelector = {}
          serviceMonitorSelectorNilUsesHelmValues = false
          #nodeSelector = { "eks.amazonaws.com/nodegroup" = "private-workers" }
          nodeSelector = { "karpenter.sh/capacity-type" = "spot" }
          storageSpec = {
            # Cambia a 2 solo si necesitas Alta Disponibilidad Real duplicando discos gp3
            replicas = 1
            volumeClaimTemplate = {
              spec = {
                accessModes      = ["ReadWriteOnce"]
                storageClassName = "gp3"
                resources = {
                  requests = {
                    storage = "10Gi"
                  }
                }
              }
            }
          }
        }
      }

      # 3 Componentes Core de Monitoreo del Cluster
      kubeStateMetrics = { enabled = true }
      nodeExporter     = { enabled = false }

      # 4 CONFIGURACIÓN DE ALERTMANAGER (ENVÍO DE NOTIFICACIONES)
      alertmanager = {
        enabled = true
        apiVersion = "v2"

        # Configuración de los canales de destino
        config = {
          global = {
            # Si usas Slack, aquí defines el Webhook general (puedes usar una variable de Terraform)
            smtp_smarthost = "smtp.gmail.com:587" #"smtp.hostinger.com:587"
            smtp_from = "rodrigojimen@gmail.com" #"contact@rj-engineering.com"             # Tu dirección de Gmail
            smtp_auth_username = "rodrigojimen@gmail.com"    # Tu correo completo
            smtp_auth_password = "cibf bnrv znpb bzoa"       # La contraseña de aplicación de 16 caracteres (sin espacios)
            smtp_require_tls = true

            slack_api_url = "https://slack.com"
          }

          # Enrutamiento de las alertas
          route = {
            group_by = ["namespace", "alertname"] # Agrupa alertas similares para no saturar
            group_wait = "30s"                    # Espera 30s para ver si llegan más alertas del mismo tipo
            group_interval = "5m"                 # Intervalo para enviar alertas agrupadas
            repeat_interval = "4h"                # Si la alerta sigue activa, repite la notificación cada 4 horas
            receiver = "email"                    # Receptor por defecto
            routes = [
              {
                matchers = ["alertname =~ \"Watchdog|NginxIngressTrafficDropToZero\""]
                receiver = "null"
              }
            ]
          }

          # Definición de los Receptores (Canales)
          receivers = [
            { name = "null" },
            {
              # 🎯 2. CONFIGURACIÓN DEL RECEPTOR DE CORREO
              name = "email"
              email_configs = [
                {
                  to = "rodrigojimen@gmail.com" # A quién le llegan las alertas
                  send_resolved = true          # Notifica cuando el problema se resuelva

                  # Formato del mensaje en HTML
                  html = <<-HTML
                    <h2>[{{ .Status | toUpper }}] {{ .GroupLabels.alertname }} ({{ .Alerts | len }} alerta/s)</h2>
                    {{ range .Alerts }}
                      <div style="border-bottom: 1px solid #ccc; padding-bottom: 10px; margin-bottom: 10px;">
                      <p><b>Pod / Componente:</b> {{ .Labels.pod }}</p>
                      <p><b>Namespace:</b> {{ .Labels.namespace }}</p>
                      <p><b>Severidad:</b> {{ .Labels.severity }}</p>
                      <p><b>Descripción:</b> {{ .Annotations.description }}</p>

                      {{ if .Annotations.grafana_url }}
                        <p style="margin-top: 10px;">
                        <a href="{{ .Annotations.grafana_url }}"
                          style="background-color: #3274D9; color: #ffffff; padding: 8px 12px; text-decoration: none; border-radius: 4px; font-weight: bold; display: inline-block;">
                          🔍 Ver Logs del Error en Grafana
                        </a>
                        </p>
                      {{ end }}
                      </div>
                    {{ end }}
                  HTML
                }
              ]
            },
            {
              name = "slack-default"
              slack_configs = [
                {
                  channel = "#alertas-cluster"
                  send_resolved = true            # Envía una notificación cuando el problema se solucione
                  title = "[[{{ .Status | toUpper }}]] {{ .CommonLabels.alertname }}"
                  text = "• *Descripción:* {{ .CommonAnnotations.description }}\n• *Namespace:* {{ .CommonLabels.namespace }}\n• *Severidad:* {{ .CommonLabels.severity }}"
                }
              ]
            }
          ]
        }

        # Almacenamiento persistente para Alertmanager (Evita perder el estado de silencios si el Pod se reinicia)
        alertmanagerSpec = {
          #nodeSelector = { "eks.amazonaws.com/nodegroup" = "private-workers" }
          nodeSelector = { "karpenter.sh/capacity-type" = "spot" }
          storage = {
            volumeClaimTemplate = {
              spec = {
                accessModes      = ["ReadWriteOnce"]
                storageClassName = "gp3"
                resources = {
                  requests = {
                    storage = "10Gi"
                  }
                }
              }
            }
          }
        }
      }
      # 5 DEFINICIÓN DE REGLAS DE ALERTA PERSONALIZADAS (MÉTRICAS DE PODS Y NODOS)
      additionalPrometheusRulesMap = {
        "reglas-personalizadas" = {
          groups = [
            {
              name = "alertas-performance"
              rules = [
                # Alerta 1: Pod atrapado sin Memoria (Riesgo de OOMKilled o VPA requerido)
                {
                  alert = "KubernetesPodMemoryHigh"
                  expr  = "sum(container_memory_working_set_bytes{container!=\"\"}) by (pod, namespace) / sum(kube_pod_container_resource_limits{resource=\"memory\"}) by (pod, namespace) * 100 > 85"
                  for = "5m" # La condición debe mantenerse por 5 minutos seguidos
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "Uso de memoria crítico en el Pod {{ $labels.pod }}"
                    description = "El Pod {{ $labels.pod }} en el namespace {{ $labels.namespace }} está utilizando más del 85% de su límite de memoria asignado."
                  }
                },
                # Alerta 2: CPU de un Nodo saturado (Ideal para revisar el Cluster Autoscaler)
                {
                  alert = "KubernetesNodeCPUHigh"
                  expr  = "100 - (avg by(instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100) > 90"
                  for   = "10m"
                  labels = { severity = "critical" }
                  annotations = {
                    summary     = "Saturación de CPU en el Nodo {{ $labels.instance }}"
                    description = "El nodo de AWS {{ $labels.instance }} tiene un uso de CPU sostenido por encima del 90% durante los últimos 10 minutos."
                  }
                }
              ]
            },
            {
              name = "alertas-nginx-red"
              rules = [
                # 1. ERRORES: Alerta si la tasa de errores HTTP 5xx supera el 5% del tráfico en el último minuto
                {
                  alert = "NginxIngressHighHttp5xxErrorRate"
                  expr  = "sum(rate(nginx_ingress_controller_requests{status=~\"5.*\"}[1m])) by (ingress, namespace) / sum(rate(nginx_ingress_controller_requests[1m])) by (ingress, namespace) * 100 > 5"
                  for   = "2m" # Debe mantenerse por 2 minutos seguidos para evitar falsos positivos
                  labels = { severity = "critical" }
                  annotations = {
                    summary     = "Tasa de errores 5xx alta en Ingress {{ $labels.ingress }}"
                    description = "El Ingress {{ $labels.ingress }} en el namespace {{ $labels.namespace }} está experimentando una tasa de errores HTTP 5xx superior al 5% en los últimos minutos. Esto indica fallas críticas en los Pods de la aplicación (Crashes, Bad Gateway o Timeout)."
                  }
                },

                # 2. DURACIÓN (LATENCIA): Alerta si el percentil 95 de la latencia supera los 2 segundos
                {
                  alert = "NginxIngressHighLatencyP95"
                  expr  = "histogram_quantile(0.95, sum(rate(nginx_ingress_controller_request_duration_seconds_bucket[1m])) by (le, ingress, namespace)) > 2"
                  for   = "5m"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "Latencia P95 elevada en Ingress {{ $labels.ingress }}"
                    description = "El 95% de los usuarios que acceden a través del Ingress {{ $labels.ingress }} (namespace {{ $labels.namespace }}) están experimentando tiempos de respuesta mayores a 2 segundos. La aplicación está respondiendo lenta."
                  }
                },

                # 3. RENDIMIENTO (ANOMALÍA EN VOLUMEN DE RENDIMIENTO / REQUESTS): Alerta si el tráfico cae a cero de golpe
                # Útil para detectar fallas masivas de red, DNS caídos o si eliminaste un Ingress por error.
                /*{
                  alert = "NginxIngressTrafficDropToZero"
                  #expr  = "sum(rate(nginx_ingress_controller_requests[5m])) by (ingress, namespace) == 0 and sum(retrieval_at_time(nginx_ingress_controller_requests[1h] offset 1h)) by (ingress, namespace) > 0"
                  expr  = "sum(rate(nginx_ingress_controller_requests[5m])) by (ingress, namespace) == 0 and sum(rate(nginx_ingress_controller_requests[5m] offset 1h)) by (ingress, namespace) > 0"
                  for   = "3m"
                  labels = { severity = "critical" }
                  annotations = {
                    summary     = "Caída total de tráfico en Ingress {{ $labels.ingress }}"
                    description = "El tráfico del Ingress {{ $labels.ingress }} en el namespace {{ $labels.namespace }} ha caído a cero de forma absoluta en los últimos 5 minutos, habiendo tenido tráfico activo la hora pasada. Revisa el estado de la red, DNS o si los pods perdieron conectividad."
                  }
                }*/
              ]
            }
            /*{
              name = "alertas-logs-loki"
              rules = [
                {
                  alert = "LogContainsErrorPattern"
                  # Cuenta la tasa de logs que contienen 'error' o 'ERROR' en los últimos 5 minutos
                  expr  = "sum(rate({namespace=~\".+\"} |= \"error\" [5m])) > 0"
                  for   = "1m"
                  labels = {
                    severity = "warning"
                  }
                  annotations = {
                    summary     = "Se han detectado errores en los logs del namespace {{ $labels.namespace }}"
                    description = "El pod {{ $labels.pod }} ha emitido logs que contienen la palabra 'error'."
                  }
                }
              ]
            }*/
          ]
        }
      }
    })
  ]

  # ... Tu configuración previa de Grafana y Prometheus permanece igual


  # La password no va en `values` para que no acabe en el diff en claro.
  /*set_sensitive {
    name  = "grafana.adminPassword"
    value = random_password.grafana_admin.result
  }*/

  # OBLIGATORIO: esperar a que EKS y sus nodos esten Ready antes de inyectar Helm
  depends_on = [
    aws_iam_role_policy_attachment.grafana_cloudwatch_readonly,
    helm_release.nginx_ingress
  ]
}





