#  Trust Role for grafana service account for AWS CLoudWatch (Actually not used)
resource "aws_iam_role" "grafana_aws_reader" {
  count       = var.enable_monitoring ? 1 : 0
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
          "${var.eks.oidc_issuer}:sub" = "system:serviceaccount:monitoring:kube-prometheus-stack-grafana"
          "${var.eks.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "grafana_cloudwatch_readonly" {
  count      = var.enable_monitoring ? 1 : 0
  role       = aws_iam_role.grafana_aws_reader[0].name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}


# Credenciales Grafana
resource "random_password" "grafana_admin" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "grafana_admin" {
  count                   = var.enable_monitoring ? 1 : 0
  name                    = "${var.environment}/grafana/admin-password"
  recovery_window_in_days = 0 # 👈 Fuerza borrado inmediato si Terraform lo destruye
  description             = "Grafana admin password for the kube-prometheus-stack release"
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  count         = var.enable_monitoring ? 1 : 0
  secret_id     = aws_secretsmanager_secret.grafana_admin[0].id
  secret_string = random_password.grafana_admin.result
}

# Adjuntar la política oficial administrada por AWS para controladores EBS
/*resource "aws_iam_role_policy_attachment" "ebs_csi_policy" {
  count      = var.environment == "prod" ? 1 : 0
  role       = var.storage.ebs_csi_driver_rol_name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}*/


resource "helm_release" "kube_prometheus_stack" {
  count            = var.enable_monitoring ? 1 : 0
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
        priorityClassName = "system-cluster-critical"
        enabled       = true
        adminPassword = random_password.grafana_admin.result
        nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
        serviceAccount = {
          create = true
          annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.grafana_aws_reader[0].arn }
        }
        #grafana.ini = { users = { default_timezone = "Europe/Madrid" } }
        resources = {
          requests = {
            cpu    = "200m"
            memory = "512Mi"
          }
          limits = {
            cpu    = "300m"
            memory = "700Mi"
          }
        }
        persistence = {
          enabled          = true
          type             = "pvc"
          storageClassName = "gp3"
          accessModes      = ["ReadWriteOnce"]
          size             = "10Gi"
        }
        ingress = {
          enabled          = true
          ingressClassName = "nginx" # Apunta a nuestro Ingress Controller
          hosts = ["grafana.aws.rj-engineering.com"]
          paths = ["/"]
          annotations = {
            "cert-manager.io/cluster-issuer"               = "letsencrypt-${var.environment}"
            "nginx.ingress.kubernetes.io/backend-protocol" = "HTTP"
            "nginx.ingress.kubernetes.io/ssl-redirect"     = "true"
          }
          tls = [
            {
              hosts      = ["grafana.aws.rj-engineering.com"]
              secretName = "grafana-server-tls-secret"
            }
          ]
        }

        # Conectar la interfaz de Grafana con la API de Alertmanager
        alertmanager = {
          enabled = true
          url = "http://kube-prometheus-stack-alertmanager.monitoring.svc:9093"
        }

        # 🎯 Registrar Alertmanager como Data Source nativo en Grafana
        additionalDataSources = [
          {
            name   = "Alertmanager"
            type   = "alertmanager"
            uid    = "alertmanager"
            url    = "http://kube-prometheus-stack-alertmanager.monitoring.svc:9093"
            access = "proxy"
            jsonData = {
              implementation = "prometheus"
            }
          },
          {
            name   = "Loki"
            type   = "loki"
            uid    = "loki"
            url    = "http://loki-gateway.monitoring.svc:80" #"http://loki.monitoring.svc:3100"
            access = "proxy"
            jsonData = {
              maxLines = 1000
              derivedFields = [
                {
                  matcherRegex  = "(?:trace_?id|traceId)[\"':= ]+([a-f0-9]+)"
                  name          = "TraceID"
                  url           = "$${__value.raw}"
                  datasourceUid = "tempo"
                }
              ]
            }
          },
          {
            name   = "Tempo"
            type   = "tempo"
            uid    = "tempo"
            url    = "http://tempo.monitoring.svc:3100"
            access = "proxy"
            jsonData = {
              httpMethod = "GET"
              # 👉 Correlación Trace -> Logs (Salta de un Span en Tempo a los logs en Loki)
              tracesToLogsV2 = {
                datasourceUid      = "loki"
                spanStartTimeShift = "-2m"
                spanEndTimeShift   = "2m"
                filterByTraceId    = false
                filterBySpanId     = false
                customTags = [
                  { key = "k8s.pod.name", value = "k8s_pod_name" },
                  { key = "k8s.namespace.name", value = "k8s_namespace_name" }
                ]
              }
              # 👉 Habilitar Service Graph / Service Map
              serviceMap = { datasourceUid = "prometheus" }
              nodeGraph  = { enabled = true }
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
            # Descarga e instala automáticamente el Dashboard oficial de Ingress-NGINX
            ingress-nginx = {
              gnetId     = 9614
              revision   = 1
              datasource = "Prometheus"
            }
            # Dashboard comunitario de Argo CD
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
            node-exporter-full = {
              gnetId     = 1860
              revision   = 37
              datasource = "Prometheus"
            }
            karpenter-full = {
              gnetId     = 20398
              revision   = 2
              datasource = "Prometheus"
            }
            redis-overview = {
              gnetId     = 763
              revision   = 1
              datasource = "Prometheus"
            }
            rabbitmq-overview = {
              gnetId     = 10991
              revision   = 1
              datasource = "Prometheus"
            }
            redis-sentinel = {
              gnetId     = 11835
              revision   = 1
              datasource = "Prometheus"
            }
            rabbitmq-queues = {
              gnetId     = 14081
              revision   = 1
              datasource = "Prometheus"
            }
            /*kafka-clusters = {
              gnetId     = 11281
              revision   = 1
              datasource = "Prometheus"
            }
            kafka-consumers = { gnetId = 11282 , revision   = 37, datasource = "Prometheus" }*/
            # 🎯 Dashboard oficial para Postgres Exporter (Sin CloudWatch)
            postgres-overview = { gnetId = 9628, revision = 7, datasource = "Prometheus" }

            /*kubecost-cluster = {
              gnetId     = 15132
              revision   = 1
              datasource = "Prometheus"
            }
            kubecost-namespace = {
              gnetId     = 15133
              revision   = 1
              datasource = "Prometheus"
            }*/
          }
        }
      }

      # Configuracion del Almacenamiento Persistente de Prometheus
      prometheus = {
        priorityClassName = "system-cluster-critical"
        prometheusSpec = {

          replicas = 1  # Súbelo a 2 solo si requieres Alta Disponibilidad real

          # 🎯 DESACTIVAR FILTROS DE ETIQUETAS Y NAMESPACES PARA REGLAS
          # Permite que Prometheus lea CUALQUIER PrometheusRule creada en el clúster
          ruleNamespaceSelector         = {}
          ruleSelectorNilUsesHelmValues = false

          # Permite buscar ServiceMonitors en cualquier namespace del clúster
          serviceMonitorNamespaceSelector         = {}
          serviceMonitorSelectorNilUsesHelmValues = false

          # Intervalo por defecto para extraer métricas si el ServiceMonitor no especifica uno
          scrapeInterval = "15s"
          evaluationInterval = "15s" # Intervalo por defecto para evaluar las reglas de alerta
          nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
          resources = {
            requests = {
              cpu    = "700m"
              memory = "2.5Gi"
            }
            limits = {
              cpu    = "1200m"
              memory = "4Gi"
            }
          }
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
      # Deploymnet con service monitor, se conecta al API Server de Kubernetes para extraer información sobre el estado de los objetos del clúster
      # (Deployments, Pods, StatefulSets, PersistentVolumeClaims, etc.)
      # Algunas metricas: kube_deployment_status_replicas_available, kube_pod_container_status_restarts_total,kube_horizontalpodautoscaler_status_current_replicas, kube_pod_container_resource_limits
      kubeStateMetrics = {
        enabled           = true
        priorityClassName = "system-cluster-critical"
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
      # DaemonSet en cada nodo de infraestructura para medir los recursos físicos o virtuales del host.
      # Algunaas metricas: node_cpu_seconds_total por modo (idle, system, user, iowait), node_memory_MemAvailable_bytes, node_disk_io_time_seconds_total, node_network_receive_bytes_total,node_network_transmit_bytes_total
      nodeExporter = {
        enabled           = true
        priorityClassName = "system-node-critical"
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

      prometheusOperator = {
        enabled = true
        priorityClassName = "system-cluster-critical"
        nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
        resources = {
          requests = {
            cpu    = "25m"
            memory = "64Mi"
          }
          limits = {
            cpu    = "100m"
            memory = "128Mi"
          }
        }
      }

      # Kubelet exporta métricas del nodo en sí,  cAdvisor (integrado en Kubelet) extrae el consumo real a nivel de contenedor.
      # Deploy service monitor to access kubelet metrics
      # Algunas metricas: container_cpu_usage_seconds_total, container_memory_working_set_bytes, kubelet_volume_stats_used_bytes / capacity_bytes (for PVC usage), kube_node_status_condition (per instance MemoryPressure (10% free memory) o DiskPressure (10% free disk))
      kubelet = {
        enabled = true
        serviceMonitor = { cAdvisor = true }
      }

      # 4 CONFIGURACIÓN DE ALERTMANAGER (ENVÍO DE NOTIFICACIONES)
      alertmanager = {
        enabled    = true
        apiVersion = "v2"
        priorityClassName = "system-cluster-critical"

        # Configuración de los canales de destino
        config = {
          global = {
            # Si usas Slack, aquí defines el Webhook general (puedes usar una variable de Terraform)
            smtp_smarthost     = "smtp.gmail.com:587"     #"smtp.hostinger.com:587"
            smtp_from          = "rodrigojimen@gmail.com" #"contact@rj-engineering.com"             # Tu dirección de Gmail
            smtp_auth_username = "rodrigojimen@gmail.com" # Tu correo completo
            smtp_auth_password = "cibf bnrv znpb bzoa"    # La contraseña de aplicación de 16 caracteres (sin espacios)
            smtp_require_tls   = true

            slack_api_url = "https://slack.com"
          }

          # Enrutamiento de las alertas
          route = {
            group_by        = ["namespace", "alertname"] # Agrupa alertas similares para no saturar
            group_wait      = "30s"                      # Espera 30s para ver si llegan más alertas del mismo tipo
            group_interval  = "5m"                       # Intervalo para enviar alertas agrupadas
            repeat_interval = "4h"                       # Si la alerta sigue activa, repite la notificación cada 4 horas
            receiver        = "email"                    # Receptor por defecto
            routes = [
              {
                matchers = ["alertname =~ \"Watchdog|NginxIngressTrafficDropToZero|KubeControllerManagerDown|KubeSchedulerDown\""]
                receiver = "null"
              },
              #{
              #  matchers = ["severity = \"critical\""] # 👈 Ejemplo: Enviar todas las alertas críticas a Teams
              #  receiver = "teams-default"
              #}
            ]
          }

          # Definición de los Receptores (Canales)
          receivers = [
            { name = "null" },
            {
              name = "email"
              email_configs = [
                {
                  to            = "rodrigojimen@gmail.com" # A quién le llegan las alertas
                  send_resolved = true                     # Notifica cuando el problema se resuelva

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
            }
            /*{
              name = "sns-critical"
              sns_configs = [
                {
                  topic_arn = aws_sns_topic.critical_alerts.arn
                  sigv4 = {
                    region = var.aws_region # Authenticates securely using IRSA role
                  }
                  attributes = {
                    key   = "severity"
                    value = "critical"
                  }
                }
              ]
            },
            {
              name = "slack-default"
              slack_configs = [
                {
                  channel       = "#alertas-cluster"
                  send_resolved = true # Envía una notificación cuando el problema se solucione
                  title         = "[[{{ .Status | toUpper }}]] {{ .CommonLabels.alertname }}"
                  text          = "• *Descripción:* {{ .CommonAnnotations.description }}\n• *Namespace:* {{ .CommonLabels.namespace }}\n• *Severidad:* {{ .CommonLabels.severity }}"
                }
              ]
            },
            {
              name = "teams-default"
              webhook_configs = [
                {
                  url           = "https://<tu-organizacion>.webhook.office.com/webhookb2/.../IncomingWebhook/.../... " # 👈 Sustituye por tu Webhook de Teams
                  send_resolved = true                                     # Notifica cuando el problema se resuelva
                }
              ]
            }*/
          ]
        }

        # Almacenamiento persistente para Alertmanager (Evita perder el estado de silencios si el Pod se reinicia)
        alertmanagerSpec = {
          nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
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
        "sre-prometheus-rules" = {
          groups = [
            # --- A) APLICACIÓN, INGRESES Y BBDD ---
            {
              name = "BusinessApplicationAlerts"
              rules = [
                {
                  alert  = "KubernetesPodMemoryHigh"
                  expr   = "sum(container_memory_working_set_bytes{container!=\"\"}) by (pod, namespace) / sum(kube_pod_container_resource_limits{resource=\"memory\"}) by (pod, namespace) * 100 > 85"
                  for    = "5m"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "Uso de memoria crítico en Pod {{ $labels.pod }}"
                    description = "El Pod {{ $labels.pod }} (namespace {{ $labels.namespace }}) supera el 85% de su límite de memoria."
                  }
                },
                # KUBERNETES WORKLOADS: Deployments que no pueden desplegar (Stuck / ImagePullBackOff)
                {
                  alert  = "KubernetesDeploymentReplicasMismatch"
                  expr   = "kube_deployment_spec_replicas{namespace!=\"monitoring\"} != kube_deployment_status_replicas_available{namespace!=\"monitoring\"}"
                  for    = "10m"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "Deployment {{ $labels.namespace }}/{{$labels.deployment }} desalineado"
                    description = "El Deployment no ha podido alcanzar el número de réplicas deseadas durante más de 10 minutos (posible ImagePullBackOff o falta de recursos)."
                  }
                },

                # KUBERNETES CORE: HPA al 100% de su capacidad (Saturación de Autoscaling)
                {
                  alert  = "KubernetesHpaMaxedOut"
                  expr   = "kube_horizontalpodautoscaler_status_current_replicas == kube_horizontalpodautoscaler_spec_max_replicas"
                  for    = "15m"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "HPA {{ $labels.namespace }}/{{$labels.horizontalpodautoscaler }} al límite máximo"
                    description = "El HPA ha alcanzado el límite máximo de réplicas (`maxReplicas`) y la carga sigue alta. Se necesita revisar límites de escalado."
                  }
                },
                {
                  alert  = "NginxIngressHighHttp5xxErrorRate"
                  expr   = "sum(rate(nginx_ingress_controller_requests{status=~\"5.*\"}[1m])) by (ingress, namespace) / sum(rate(nginx_ingress_controller_requests[1m])) by (ingress, namespace) * 100 > 5"
                  for    = "2m"
                  labels = { severity = "critical" }
                  annotations = {
                    summary     = "Tasa de errores 5xx alta en Ingress {{ $labels.ingress }}"
                    description = "El Ingress {{ $labels.ingress }} en {{ $labels.namespace }} supera el 5% de errores 5xx."
                  }
                },
                {
                  alert  = "NginxIngressHighLatencyP95"
                  expr   = "histogram_quantile(0.95, sum(rate(nginx_ingress_controller_request_duration_seconds_bucket[1m])) by (le, ingress, namespace)) > 2"
                  for    = "5m"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "Latencia P95 elevada en Ingress {{ $labels.ingress }}"
                    description = "El percentil 95 de latencia supera los 2 segundos en {{ $labels.ingress }}."
                  }
                },
                # 2. SATURACIÓN NGINX: Conexiones o Workers agotados
                {
                  alert  = "NginxIngressTooManyConnsPending"
                  expr   = "sum(nginx_ingress_controller_nginx_process_connections{state=\"waiting\"}) > 500"
                  for    = "2m"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "NGINX Ingress saturado de conexiones en espera"
                    description = "El Ingress Controller tiene más de 500 conexiones en estado 'waiting'. Considera escalar las réplicas del Ingress."
                  }
                }, /*,
                {
                  alert = "HikariCPConnectionPoolSaturated"
                  expr  = "hikaricp_connections_pending > 5"
                  for   = "2m"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "Pool de conexiones HikariCP saturado en {{ $labels.pod }}"
                    description = "Hay más de 5 hilos esperando por una conexión JDBC a la base de datos."
                  }
                }*/
              ]
            },

            # --- B) SERVICE MESH (ISTIO) ---
            {
              name = "IstioServiceMeshAlerts"
              rules = [
                # 1. CONTROL PLANE (ISTIOD)
                {
                  alert  = "IstiodDown"
                  expr   = "absent(up{job=\"istiod\"} == 1)"
                  for    = "2m"
                  labels = { severity = "critical" }
                  annotations = {
                    summary     = "Instancia de Istiod fuera de servicio"
                    description = "El pod de Control Plane 'istiod' no responde. Se detendrá el envío de nuevas configuraciones XDS y la emisión de certificados."
                  }
                },
                {
                  alert  = "IstioXdsPushLatencyHigh"
                  expr   = "histogram_quantile(0.99, sum(rate(pilot_xds_push_time_bucket[5m])) by (le)) > 3"
                  for    = "5m"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "Latencia alta en distribución XDS"
                    description = "El P99 del tiempo de propagación de cambios XDS desde istiod a los proxies excede los 3 segundos."
                  }
                },
                {
                  alert  = "IstioCAErrorRateHigh"
                  expr   = "sum(rate(pilot_total_xds_rejects[5m])) > 0"
                  for    = "5m"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "Rechazo de configuraciones XDS o problemas de certificados"
                    description = "Istiod está rechazando configuraciones XDS presentadas por los proxies o experimenta anomalías en la CA."
                  }
                },
                {
                  alert  = "IstioCertExpiring30Days"
                  expr   = "(citadel_server_root_cert_expiry_timestamp - time()) < (30 * 24 * 3600)"
                  for    = "5m"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "Certificado Istio expira en 30 dias"
                    description = "Certificado Istio expira en 30 dias"
                  }
                },
                # 2. DATA PLANE L4 (ZTUNNEL - AMBIENT MESH)
                {
                  alert  = "IstioZtunnelDaemonSetKilled"
                  expr   = "(kube_daemonset_status_number_ready{daemonset=\"ztunnel\"} / kube_daemonset_status_desired_number_scheduled{daemonset=\"ztunnel\"}) < 1"
                  for    = "2m"
                  labels = { severity = "critical" }
                  annotations = {
                    summary     = "Ztunnel DaemonSet no está 100% disponible"
                    description = "Uno o más nodos no tienen un pod 'ztunnel' activo. El tráfico mTLS/HBONE en esos nodos se verá interrumpido."
                  }
                },
                {
                  alert  = "IstioZtunnelConnectionErrors"
                  expr   = "sum(rate(ztunnel_connection_errors_total[5m])) > 0"
                  for    = "5m"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "Errores de conexión mTLS en ztunnel"
                    description = "Se detectan fallos o caídas en el establecimiento de túneles mTLS (HBONE) entre nodos."
                  }
                },
                {
                  alert  = "IstioZtunnelCertValidationFailed"
                  expr   = "sum(rate(ztunnel_cert_validation_errors_total[5m])) > 0"
                  for    = "2m"
                  labels = { severity = "critical" }
                  annotations = {
                    summary     = "Fallo de validación de certificados TLS en ztunnel"
                    description = "ztunnel no puede validar la identidad mTLS de los pods del nodo."
                  }
                },

                # 3. APLICACIÓN L7 & RESILIENCIA (WAYPOINTS / INGRESS / ENVOY)
                {
                  alert  = "IstioHighRequestErrorRate"
                  expr   = "(sum(rate(istio_requests_total{reporter=\"destination\", response_code=~\"5.*\"}[2m])) by (destination_workload, destination_workload_namespace) / sum(rate(istio_requests_total{reporter=\"destination\"}[2m])) by (destination_workload, destination_workload_namespace)) * 100 > 5"
                  for    = "2m"
                  labels = { severity = "critical" }
                  annotations = {
                    summary     = "Alta tasa de errores L7 en {{ $labels.destination_workload }}"
                    description = "El workload {{ $labels.destination_workload }} registra más de un 5% de errores 5xx en la malla."
                  }
                },
                {
                  alert  = "IstioServiceHighLatencyP99"
                  expr   = "histogram_quantile(0.99, sum(rate(istio_request_duration_milliseconds_bucket{reporter=\"destination\"}[5m])) by (le, destination_workload)) > 2000"
                  for    = "5m"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "Latencia P99 superior a 2s en {{ $labels.destination_workload }}"
                    description = "El 1% de las peticiones HTTP tarda más de 2000ms en completarse en la capa L7."
                  }
                },
                {
                  alert  = "IstioCircuitBreakerTripped"
                  expr   = "sum(rate(envoy_cluster_upstream_rq_pending_overflow[5m])) > 0"
                  for    = "2m"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "Circuit Breaker activado en proxy Istio"
                    description = "Se han rechazado peticiones por exceso de llamadas salientes/pendientes hacia el servicio destino."
                  }
                },
                {
                  alert  = "IstioCircuitBreakerEjectedHost"
                  expr   = "sum(rate(envoy_cluster_outlier_detection_ejections_enforced_total[2m])) by (pod, namespace) > 0"
                  for    = "1m"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "Circuit Breaker activado en Envoy Proxy ({{ $labels.namespace }}/{{$labels.pod }})"
                    description = "Istio/Envoy ha expulsado automáticamente una instancia del pool por acumular demasiados errores de red o timeouts."
                  }
                },
                # ─── 1. SLI DE DISPONIBILIDAD: BURN RATE RÁPIDO (1h) ───
                {
                  alert = "ServiceErrorBudgetBurnRateFast"
                  expr  = "sum(rate(istio_requests_total{reporter=\"destination\", response_code=~\"5.*\"}[1h])) by (destination_workload, destination_workload_namespace) / sum(rate(istio_requests_total{reporter=\"destination\"}[1h])) by (destination_workload, destination_workload_namespace) > (1 - 0.999) * 14.4"
                  for    = "2m"
                  labels = { severity = "critical", tier = "slo" }
                  annotations = {
                    summary     = "Consumo crítico de Error Budget en {{ $labels.destination_workload }}"
                    description = "El microservicio {{ $labels.destination_workload }} (namespace {{ $labels.destination_workload_namespace }}) tiene un Burn Rate rápido (>14.4x)."
                    grafana_url = "https://grafana.aws.rj-engineering.com/explore"
                  }
                },

                # ─── 2. SLI DE DISPONIBILIDAD: BURN RATE LENTO (6h) ───
                {
                  alert = "ServiceErrorBudgetBurnRateSlow"
                  expr  = "sum(rate(istio_requests_total{reporter=\"destination\", response_code=~\"5.*\"}[6h])) by (destination_workload, destination_workload_namespace) / sum(rate(istio_requests_total{reporter=\"destination\"}[6h])) by (destination_workload, destination_workload_namespace) > (1 - 0.999) * 6"
                  for    = "15m"
                  labels = { severity = "warning", tier = "slo" }
                  annotations = {
                    summary     = "Degradación sostenida: Error Budget consumiéndose en {{ $labels.destination_workload }}"
                    description = "El microservicio {{ $labels.destination_workload }} presenta una tasa de errores constante que agotará el presupuesto."
                  }
                },

                # ─── 3. SLI DE LATENCIA: Incumplimiento del umbral P95 ───
                {
                  alert = "ServiceLatencySLOViolation"
                  expr  = "histogram_quantile(0.95, sum(rate(istio_request_duration_milliseconds_bucket{reporter=\"destination\"}[5m])) by (le, destination_workload, destination_workload_namespace)) > 500 and sum(rate(istio_requests_total{reporter=\"destination\"}[5m])) by (destination_workload, destination_workload_namespace) > 1"
                  for    = "5m"
                  labels = { severity = "warning", tier = "slo" }
                  annotations = {
                    summary     = "Incumplimiento de SLO de Latencia P95 en {{ $labels.destination_workload }}"
                    description = "El percentil 95 de latencia para el microservicio {{ $labels.destination_workload }} supera los 500ms durante los últimos 5 minutos."
                  }
                }
              ]
            },
            # --- C) KAFKA & STRIMZI ---
            {
              name = "KafkaAlerts"
              rules = [
                # 1. SALUD CRÍTICA DEL CLÚSTER: Pérdida del Controller de Kafka
                # Si no hay ningún Broker actuando como Active Controller, el clúster no puede procesar metadatos ni cambios de partición.
                {
                  alert  = "KafkaNoActiveController"
                  expr   = "sum(kafka_controller_kafkacontroller_activecontrollercount) == 0"
                  for    = "1m"
                  labels = { severity = "critical" }
                  annotations = {
                    summary     = "¡Sin Active Controller en el clúster de Kafka!"
                    description = "El clúster de Kafka no tiene un Controller activo. Se han bloqueado todas las operaciones de metadatos y coordinación."
                  }
                },

                # 2. SALUD CRÍTICA DEL CLÚSTER: Múltiples Controllers activos (Split-Brain)
                {
                  alert  = "KafkaMultipleActiveControllers"
                  expr   = "sum(kafka_controller_kafkacontroller_activecontrollercount) > 1"
                  for    = "1m"
                  labels = { severity = "critical" }
                  annotations = {
                    summary     = "Múltiples Active Controllers en Kafka (Split-Brain)"
                    description = "Se detecta más de un Active Controller en el clúster. Posible partición de red o corrupción de estado en Zookeeper/KRaft."
                  }
                },

                # 3. REPLICACIÓN Y DISPONIBILIDAD: Particiones Offline (Sin líder)
                # Ocurre cuando un broker cae y ninguna réplica está en ISR para asumir la jefatura. Los clientes no pueden leer ni escribir en ese tópico.
                {
                  alert  = "KafkaOfflinePartitionsCount"
                  expr   = "sum(kafka_controller_kafkacontroller_offlinepartitionscount) > 0"
                  for    = "1m"
                  labels = { severity = "critical" }
                  annotations = {
                    summary     = "Particiones Offline detectadas en Kafka"
                    description = "Hay particiones sin líder disponible. La lectura/escritura en los tópicos afectados está interrumpida."
                  }
                },

                # 4. REPLICACIÓN: Particiones Sub-replicadas (Under-Replicated Partitions)
                {
                  alert  = "KafkaUnderReplicatedPartitions"
                  expr   = "sum(kafka_server_replicamanager_underreplicatedpartitions) > 0"
                  for    = "3m"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "Particiones Sub-replicadas en Kafka"
                    description = "Hay particiones que no tienen todas sus réplicas sincronizadas en el ISR. Riesgo de pérdida de datos si cae otro broker."
                  }
                },

                # 5. RENDIMIENTO / LECTURA: Consumer Lag Elevado (Acumulación de mensajes)
                {
                  alert  = "KafkaConsumerLagHigh"
                  expr   = "sum(kafka_consumergroup_lag) by (consumergroup, topic) > 10000"
                  for    = "5m"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "Consumer Lag elevado en grupo {{ $labels.consumergroup }}"
                    description = "El grupo de consumo {{ $labels.consumergroup }} tiene un retraso acumulado superior a 10,000 mensajes en el tópico {{ $labels.topic }}."
                  }
                },

                # 6. CONSUMIDORES ZOMBIE: Grupo de consumo bloqueado o estancado (Lag sin procesamiento)
                # Si el lag sigue subiendo y la tasa de procesamiento es 0, los Pods consumidores están colgados o en Deadlock.
                {
                  alert  = "KafkaConsumerGroupStalled"
                  expr   = "sum(rate(kafka_consumergroup_current_offset[5m])) by (consumergroup, topic) == 0 and sum(kafka_consumergroup_lag) by (consumergroup, topic) > 1000"
                  for    = "5m"
                  labels = { severity = "critical" }
                  annotations = {
                    summary     = "Grupo de consumo estancado: {{ $labels.consumergroup }}"
                    description = "El grupo {{ $labels.consumergroup }} ha dejado de procesar mensajes por completo en el tópico {{ $labels.topic }} mientras el lag sigue subiendo."
                  }
                },

                # 7. PRODUCTORES / RED: Caída drástica o anormal en la producción de mensajes
                {
                  alert  = "KafkaTopicBytesInDropToZero"
                  expr   = "sum(rate(kafka_server_brokertopicmetrics_bytesin_total[5m])) by (topic) == 0 and sum(rate(kafka_server_brokertopicmetrics_bytesin_total[5m] offset 1h)) by (topic) > 10000"
                  for    = "3m"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "Caída repentina de entrada de datos en tópico {{ $labels.topic }}"
                    description = "El tráfico de entrada en el tópico {{ $labels.topic }} ha caído a cero respecto a la hora anterior. Posible fallo en los Productores."
                  }
                },

                # 8. RECURSOS DEL BROKER: Solicitudes locales purgadas / Requests rechazadas (Purged Request Queue)
                {
                  alert  = "KafkaRequestQueueTimeHigh"
                  expr   = "sum(rate(kafka_network_requestmetrics_localqueuetime_ms_sum[1m])) / sum(rate(kafka_network_requestmetrics_localqueuetime_ms_count[1m])) > 1000"
                  for    = "3m"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "Cola de peticiones saturada en Kafka Broker {{ $labels.pod }}"
                    description = "El tiempo en cola de las peticiones dentro del Broker ha superado 1 segundo. El broker está sufriendo I/O o CPU bottleneck."
                  }
                },

                # 9. DISCO / OPERAClÓN: Fallos en los directorios de logs del Broker (Log Directory Failures)
                {
                  alert  = "KafkaLogDirectoryFailed"
                  expr   = "sum(kafka_log_logmanager_offline_log_directory_count) > 0"
                  for    = "0m"
                  labels = { severity = "critical" }
                  annotations = {
                    summary     = "Directorio de almacenamiento fallido en Kafka {{ $labels.pod }}"
                    description = "Un volumen EBS o disco adjunto al Broker ha fallado o se ha montado en modo Solo Lectura."
                  }
                },
                # ─── SLI 1: Tasa de Errores de Escritura (Productores) ───
                {
                  alert = "KafkaProducerErrorRateHigh"
                  expr  = "sum(rate(kafka_network_requestmetrics_requests_total{request=\"Produce\", error!=\"NONE\"}[5m])) / sum(rate(kafka_network_requestmetrics_requests_total{request=\"Produce\"}[5m])) * 100 > 1"
                  for   = "2m"
                  labels = { severity = "critical", tier = "slo" }
                  annotations = {
                    summary     = "Tasa elevada de errores de escritura en Kafka"
                    description = "Más del 1% de las peticiones de producción (Produce) hacia el clúster de Kafka están devolviendo errores."
                  }
                },

                # ─── SLI 2: Tasa de Errores de Lectura/Entrega (Consumidores / Fetch) ───
                {
                  alert = "KafkaConsumerFetchErrorRateHigh"
                  expr  = "sum(rate(kafka_network_requestmetrics_requests_total{request=\"Fetch\", error!=\"NONE\"}[5m])) / sum(rate(kafka_network_requestmetrics_requests_total{request=\"Fetch\"}[5m])) * 100 > 1"
                  for   = "2m"
                  labels = { severity = "critical", tier = "slo" }
                  annotations = {
                    summary     = "Tasa elevada de errores de entrega a consumidores en Kafka"
                    description = "Más del 1% de las peticiones de lectura (Fetch) desde los consumidores hacia el clúster de Kafka están fallando."
                  }
                }
              ]
            },

            # --- D) NODOS, KARPENTER Y EC2 SPOT ---
            {
              name = "InfrastructureNodesAndKarpenter"
              rules = [
                {
                  alert  = "KubernetesNodeCPUHigh"
                  expr   = "100 - (avg by(instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100) > 90"
                  for    = "10m"
                  labels = { severity = "critical" }
                  annotations = {
                    summary     = "Saturación de CPU en Nodo {{ $labels.instance }}"
                    description = "El nodo de AWS {{ $labels.instance }} tiene un uso de CPU sostenido superior al 90%."
                  }
                },
                {
                  alert  = "EC2SpotNodeTerminationWarning"
                  expr = "increase(aws_node_termination_handler_spot_itn_events_total[5m]) > 0"
                  for    = "0m"
                  labels = { severity = "critical" }
                  annotations = {
                    summary     = "Aviso de interrupción Spot en nodo {{ $labels.node }}"
                    description = "AWS ha notificado la interrupción de 2 minutos para {{ $labels.node }}. Draining en proceso."
                    grafana_url = "https://grafana.aws.rj-engineering.com/d/1860/node-exporter-full?var-node={{ $labels.node }}"
                  }
                },
                {
                  alert  = "KarpenterNodeAllocationFailed"
                  expr   = "sum(rate(karpenter_nodepool_failed_allocations_total[5m])) > 0"
                  for    = "2m"
                  labels = { severity = "critical" }
                  annotations = {
                    summary     = "Fallo de aprovisionamiento en Karpenter"
                    description = "Karpenter no puede lanzar nuevas instancias EC2 en AWS."
                  }
                },
                # 6. MEMORIA / DISCO EN NODOS: Riesgo de OOM o Presión de Disco (Kubelet Node Conditions)
                {
                  alert  = "KubernetesNodeMemoryPressure"
                  expr   = "kube_node_status_condition{condition=\"MemoryPressure\",status=\"true\"} == 1"
                  for    = "2m"
                  labels = { severity = "critical" }
                  annotations = {
                    summary     = "El nodo {{ $labels.node }} está bajo presión de memoria (MemoryPressure)"
                    description = "Kubelet ha entrado en estado de presión de memoria en {{ $labels.node }}. Riesgo de desalojo masivo de Pods."
                  }
                },
                {
                  alert  = "KubernetesNodeDiskPressure"
                  expr   = "kube_node_status_condition{condition=\"DiskPressure\",status=\"true\"} == 1"
                  for    = "2m"
                  labels = { severity = "critical" }
                  annotations = {
                    summary     = "El nodo {{ $labels.node }} está bajo presión de disco (DiskPressure)"
                    description = "El almacenamiento efímero del nodo {{ $labels.node }} se está agotando."
                  }
                },
                {
                  alert  = "KarpenterLimitExceeded"
                  expr   = "sum(karpenter_nodepool_usage_cpu) by (nodepool) / sum(karpenter_nodepool_limit_cpu) by (nodepool) * 100 > 90"
                  for    = "5m"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "Límite de NodePool Karpenter al 90%: {{ $labels.nodepool }}"
                    description = "La NodePool {{ $labels.nodepool }} ha alcanzado el 90% de su capacidad máxima de CPU asignada."
                  }
                }
              ]
            },
            {
              name = "SSLCertificates"
              rules = [
                # 5. SEGURIDAD & EXPIRACIÓN: Certificados SSL/TLS a punto de caducar (cert-manager)
                {
                  alert  = "SSLCertificateExpiringSoon"
                  expr   = "certmanager_certificate_expiration_timestamp_seconds - time() < (30 * 24 * 3600)" # < 30 días
                  for    = "1h"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "Certificado TLS {{ $labels.name }} expira en menos de 30 días"
                    description = "El certificado TLS en {{ $labels.namespace }} expira pronto. Revisa el estado de cert-manager o Let's Encrypt."
                  }
                }
              ]
            },

            # E) OBSERVABILIDAD Y CORE KUBERNETES ---
            {
              name = "ObservabilityAndCoreK8s"
              rules = [
                {
                  alert  = "OpenTelemetryCollectorReceiverRefusedLogRecords"
                  expr   = "sum(rate(otelcol_receiver_refused_log_records[5m])) > 0"
                  for    = "2m"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "OTel Collector rechazando registros de logs"
                    description = "El OpenTelemetry Collector está rechazando logs debido a saturación o fallos de buffer."
                  }
                },
                {
                  alert  = "KubernetesPodCrashLooping"
                  expr   = "increase(kube_pod_container_status_restarts_total[10m]) > 3"
                  for    = "0m"
                  labels = { severity = "critical" }
                  annotations = {
                    summary     = "Pod en CrashLoopBackOff: {{ $labels.namespace }}/{{ $labels.pod }}"
                    description = "El contenedor ha sufrido más de 3 reinicios en los últimos 10 minutos."
                  }
                },
                {
                  alert  = "KubernetesPersistentVolumeFillingFast"
                  expr   = "(kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) * 100 > 85"
                  for    = "0m"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "Volumen PVC casi lleno en {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }}"
                    description = "El almacenamiento del volumen PVC sobrepasa el 85% de capacidad."
                  }
                }
              ]
            },
            {
              name = "RedisAlerts"
              rules = [
                # ─── REDIS ALERTS ───
                {
                  alert  = "RedisMasterDown"
                  expr   = "redis_instance_connected_slaves == 0 and sum(redis_connected_clients) > 0"
                  for    = "1m"
                  labels = { severity = "critical" }
                  annotations = {
                    summary     = "Redis Master sin réplicas conectadas"
                    description = "El nodo maestro de Redis ha perdido la conexión con sus réplicas o se encuentra aislado."
                  }
                },
                {
                  alert  = "RedisMemoryNearLimit"
                  expr   = "(redis_memory_used_bytes / redis_memory_max_bytes) * 100 > 85"
                  for    = "5m"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "Uso de memoria elevado en Redis ({{ $labels.pod }})"
                    description = "Redis está utilizando más del 85% de su memoria máxima configurada (`maxmemory`). Riesgo de expulsión de claves (eviction)."
                  }
                },
                {
                  alert  = "RedisSentinelQuorumLost"
                  expr   = "redis_sentinel_masters{status=\"disconnected\"} > 0"
                  for    = "1m"
                  labels = { severity = "critical" }
                  annotations = {
                    summary     = "Pérdida de quórum en Redis Sentinel"
                    description = "Un nodo de Sentinel no puede alcanzar al maestro configurado, poniendo en riesgo el failover automático."
                  }
                },
                {
                  alert  = "RedisCacheHitRateLow"
                  expr   = "rate(redis_keyspace_hits_total[5m]) / (rate(redis_keyspace_hits_total[5m]) + rate(redis_keyspace_misses_total[5m])) * 100 < 70"
                  for    = "10m"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "Baja tasa de aciertos (Hit Rate) en caché Redis ({{ $labels.pod }})"
                    description = "El ratio de aciertos de Redis ha bajado del 70% durante los últimos 10 minutos. Posible ineficiencia en el uso de la caché o expiración masiva."
                  }
                },
                {
                  alert  = "RedisCommandLatencyHigh"
                  expr   = "rate(redis_command_duration_seconds_total[5m]) / rate(redis_command_calls_total[5m]) > 0.01" # Promedio > 10ms por comando
                  for    = "5m"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "Latencia elevada en comandos de Redis ({{ $labels.pod }})"
                    description = "El tiempo medio de respuesta por comando en Redis supera los 10ms. Posible bloqueo por consultas pesadas o saturación de CPU."
                  }
                },


              ]
            },
            {
            name = "RabbitMQAlerts"
            rules = [
              # ─── RABBITMQ ALERTS ───
              {
                alert  = "RabbitMQNodeDown"
                expr   = "rabbitmq_running == 0"
                for    = "1m"
                labels = { severity = "critical" }
                annotations = {
                  summary     = "Nodo de RabbitMQ caído: {{ $labels.pod }}"
                  description = "El nodo de RabbitMQ ha dejado de responder o el proceso principal se ha detenido."
                }
              },
              {
                alert  = "RabbitMQMemoryAlarm"
                expr   = "rabbitmq_node_memory_used / rabbitmq_node_memory_limit > 0.85"
                for    = "3m"
                labels = { severity = "warning" }
                annotations = {
                  summary     = "Alarma de memoria en RabbitMQ ({{ $labels.pod }})"
                  description = "El consumo de RAM en RabbitMQ supera el 85% del límite configurado (high watermark). Los productores serán bloqueados temporalmente."
                }
              },
              {
                alert  = "RabbitMQHighQueueMessages"
                expr   = "rabbitmq_queue_messages > 50000"
                for    = "5m"
                labels = { severity = "warning" }
                annotations = {
                  summary     = "Acumulación masiva de mensajes en cola {{ $labels.queue }}"
                  description = "La cola {{ $labels.queue }} tiene más de 50,000 mensajes sin procesar. Posible cuello de botella en los consumidores."
                }
              },
              {
                alert  = "RabbitMQQueueWithoutConsumers"
                expr   = "rabbitmq_queue_messages > 100 and rabbitmq_queue_consumers == 0"
                for    = "3m"
                labels = { severity = "critical" }
                annotations = {
                  summary     = "Cola de RabbitMQ con mensajes retenidos y sin consumidores ({{ $labels.queue }})"
                  description = "La cola {{ $labels.queue }} tiene más de 100 mensajes pendientes pero cuenta con 0 consumidores activos. Los servicios encargados podrían haberse caído."
                }
              },
              {
                alert  = "RabbitMQMessageUnackedHigh"
                expr   = "rabbitmq_queue_messages_unacknowledged > 1000"
                for    = "5m"
                labels = { severity = "warning" }
                annotations = {
                  summary     = "Acumulación alta de mensajes sin confirmar (Unacked) en {{ $labels.queue }}"
                  description = "Hay más de 1,000 mensajes entregados pero no confirmados (ack) en la cola {{ $labels.queue }}. Posible cuello de botella o bloqueo en el procesamiento de los workers."
                }
              }
            ]
            }
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
  depends_on = [aws_iam_role_policy_attachment.grafana_cloudwatch_readonly,
    helm_release.nginx_ingress,helm_release.cert_manager,
    kubectl_manifest.karpenter_node_pool_infra]
}


# PROMETHEUS POSTGRES EXPORTER PARA AMAZON RDS
# Conexiones activas e inactivas: Comparadas contra el límite máximo configurado en RDS (max_connections) para evitar saturaciones del pool.
# Tasa de operaciones (QPS / TPS): Consultas por segundo, transacciones comprometidas (commits) frente a bloqueadas o abortadas (rollbacks).
# Rendimiento de caché (Cache Hit Ratio): Fundamental para saber si los índices están cargados en memoria o si la base de datos está sufriendo lecturas lentas a disco.
# Filas afectadas: Métricas en tiempo real de filas leídas, insertadas, actualizadas y eliminadas (SELECT, INSERT, UPDATE, DELETE).
# Bloqueos (Locks) y Deadlocks: Detección de transacciones bloqueadas esperando por recursos.
resource "helm_release" "postgres_exporter" {
  count            = var.enable_monitoring ? 1 : 0
  name             = "postgres-exporter"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "prometheus-postgres-exporter"
  version          = "8.2.0"
  namespace        = "monitoring"
  create_namespace = false

  values = [
    jsonencode({
      # Configuración de conexión a RDS mediante la Secret de AWS Secrets Manager
      config = {
        datasource = {
          host = split(":", var.db.endpoint)[0]
          user = var.db.username
          # La contraseña se obtiene dinámicamente de la master user secret gestionada por RDS
          password = "uZkVO1f?!)B-o1Jd)j<F)wm!-ipl"
          # Requires to be in same namespace
          /*passwordSecret = {
            name = "db-k8s-secret"
            key  = "password"
          }*/
          port     = "5432"
          database = var.db.name
          sslmode  = "require"
        }
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

      # Descubrimiento automático de Prometheus mediante ServiceMonitor
      serviceMonitor = {
        enabled   = true
        namespace = "monitoring"
        interval  = "30s"
        labels = { release = "kube-prometheus-stack" }
      }

      # 3. Métricas extendidas y consultas personalizadas activadas
      /*extraEnv = [
        {
          name  = "PG_EXPORTER_EXTEND_QUERY_PATH"
          value = "/etc/postgres-exporter/queries.yaml"
        }
      ]*/

      nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
    })
  ]

  depends_on = [helm_release.kube_prometheus_stack]
}


# Despliegue de AWS Node Termination Handler en modo IMDS (Sin SQS / EventBridge)
resource "helm_release" "node_termination_handler" {
  name             = "aws-node-termination-handler"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-node-termination-handler"
  version          = "0.21.0"
  namespace        = "kube-system"
  create_namespace = false

  values = [
    jsonencode({
      # 🎯 Modo IMDS: Consulta localmente los metadatos de la propia EC2
      enableSpotInterruptionDraining = true
      enableRebalanceMonitoring      = true

      # Habilita el Server de métricas para que Prometheus recopile los eventos
      enablePrometheusMetrics = true
      serviceMonitor = {
        create = true
        labels = { release = "kube-prometheus-stack" }
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

      # Solo es necesario en nodos Spot
      #nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
    })
  ]
  depends_on = [helm_release.kube_prometheus_stack]
}


