# Para escalar a cientos de microservicios en una arquitectura híbrida y multi-entorno como la tuya, Istio (con proxies Envoy) es el estándar de la industria.
# A esta escala, resuelve problemas críticos que Ingress-NGINX o Kubernetes básico no pueden gestionar: seguridad Zero-Trust con mTLS automático de servicio a servicio, observabilidad con trazas distribuidas, control granular de tráfico (Canary, Circuit Breaking, Retries) e interconexión segura con el clúster On-Premises vía VPN.
# 1. Diagrama de Arquitectura con Istio Service Mesh
# flowchart TB
#    subgraph Edge["1. Capa Edge / Ingress"]
#        NLB["AWS Network Load Balancer (L4)"]
#        IstioGW["Istio Ingress Gateway (Envoy Pods con Pod Anti-Affinity)"]
#        NLB --> IstioGW
#    end
#
#    subgraph ControlPlane["2. Istio Control Plane (modules/software)"]
#        Istiod["istiod (Pilot + Citadel + Galley)<br/>• Distribución de Configuración Envoy<br/>• Emisión de Certificados mTLS (x509)"]
#    end
#
#    subgraph MeshDataPlane["3. Data Plane en EKS (Envoy Sidecars)"]
#        subgraph PodA["Microservicio A (Namespace: dev)"]
#            AppA["Contenedor App"]
#            EnvoyA["Envoy Proxy (Sidecar)"]
#            AppA <--> EnvoyA
#        end
#
#        subgraph PodB["Microservicio B (Namespace: dev)"]
#            AppB["Contenedor App"]
#            EnvoyB["Envoy Proxy (Sidecar)"]
#            AppB <--> EnvoyB
#        end
#
#        IstioGW -->|mTLS Estricto| EnvoyA
#        EnvoyA -->|mTLS Estricto + AuthzPolicy| EnvoyB
#    end
#
#    subgraph HybridVPN["4. Malla Híbrida / Multi-Cluster (Site-to-Site VPN)"]
#        IstioEastWest["Istio East-West Gateway (AWS)"]
#        OnPremMesh["Istio Service Mesh (On-Premises Cluster)"]
#        IstioEastWest <==>|mTLS sobre VPN| OnPremMesh
#    end
#
#    subgraph Telemetry["5. Observabilidad & Malla"]
#        Kiali["Kiali (Topología de la Malla en tiempo real)"]
#        Jaeger["Jaeger / Tempo (Trazas Distribuidas)"]
#        PromGraf["Prometheus & Grafana (Métricas Envoy)"]
#    end
#
#    EnvoyA -.->|Métricas & Trazas| PromGraf
#    EnvoyB -.->|Métricas & Trazas| PromGraf
#    Istiod -.->|Control & Sync| EnvoyA
#    Istiod -.->|Control & Sync| EnvoyB


# 1. Obtener el manifiesto multi-recurso oficial
data "http" "gateway_api_crds" {
  url = "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml"
}

# 2. Parsear los documentos YAML del archivo
data "kubectl_file_documents" "gateway_api_docs" {
  content = data.http.gateway_api_crds.response_body
}

# 3. Registrar los CRDs en el API Server
resource "kubectl_manifest" "gateway_api_install" {
  for_each  = data.kubectl_file_documents.gateway_api_docs.manifests
  yaml_body = each.value
}

# 1. Istio Base (CRDs fundamentales: VirtualService, DestinationRule, etc.)
resource "helm_release" "istio_base" {
  count            = var.enable_istio ? 1 : 0
  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  version          = "1.22.0"
  namespace        = "istio-system"
  create_namespace = true
}

# 2. Istio CNI Plugin (Requisito obligatorio para modo Ambient)
# Redirige el tráfico de red de los pods al ztunnel a nivel de nodo sin necesidad de sidecars.
resource "helm_release" "istio_cni" {
  count      = var.enable_istio ? 1 : 0
  name       = "istio-cni"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "cni"
  version    = "1.22.0"
  namespace  = "istio-system"

  values = [
    yamlencode({
      profile = "ambient"
      priorityClassName = "system-node-critical"
      #nodeSelector = { "karpenter.sh/capacity-type" = "spot" }
      cni = { ambient = { dnsCapture = false } }
    })
  ]

  depends_on = [helm_release.istio_base]
}

# 2. Istio Control Plane (istiod)
resource "helm_release" "istiod" {
  count      = var.enable_istio ? 1 : 0
  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = "1.22.0"
  namespace  = "istio-system"

  values = [
    yamlencode({
      profile = "ambient"
      global = {
        meshID = "hybrid-mesh"
        #multiCluster = { clusterName = "${var.environment}-aws-cluster" }
      }

      nodeSelector = { "eks.amazonaws.com/nodegroup" = "private-workers" }

      #telemetry = { enabled = true }
      #telemetry = { enabled = true }
      # Ofertado directamente por el chart de istiod para Prometheus Operator:
      #serviceMonitor = {
      #  enabled = true
      #  additionalLabels = {
      #    release = "kube-prometheus-stack"
      #  }
      #}
      meshConfig = {
        enableAutoMtls = true # Cifrado mTLS automático entre todos los pods
        enablePrometheusMerge = true # 🎯 Fusiona métricas para que Prometheus las lea
        accessLogFile  = "/dev/stdout"
        defaultConfig = {
          proxyStatsMatcher = {
            # Incluye métricas detalladas de circuit breaker, retries y timeouts
            inclusionPrefixes = ["cluster.", "listener."]
          }
          tracing = { sampling = 10.0 } # 10% de trazas para trazabilidad distribuida sin saturar
        }
      }
      pilot = {
        autoscaleEnabled = false
        replicaCount     = 2 # Alta disponibilidad en plano de control
        env = {
          PILOT_ENABLE_AMBIENT = "true"
          #PILOT_ENABLE_XDS_IDENTITY_CHECK = "false" # 👈 Evita el rechazo de tokens xDS no estrictos en entornos EKS/AWS
          #PILOT_ENABLE_INSECURE_IMPERSONATION = "true"
        } # Activa las capacidades de Ambient Mesh en Pilot
      }
    })
  ]

  depends_on = [helm_release.istio_base, helm_release.istio_cni]
}


#  ServiceMonitor para recolectar métricas del plano de control (istiod)
resource "kubectl_manifest" "istiod_service_monitor" {
  count = var.enable_istio ? 1 : 0

  yaml_body = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: ServiceMonitor
    metadata:
      name: istiod
      namespace: istio-system
      labels:
        release: kube-prometheus-stack
    spec:
      selector:
        matchLabels:
          app: istiod
      namespaceSelector:
        matchNames:
          - istio-system
      endpoints:
        - port: http-monitoring
          interval: 15s
        - port: dns-monitoring
          interval: 15s
  YAML

  depends_on = [helm_release.istiod, helm_release.kube_prometheus_stack]
}


# 4. Istio ztunnel (DaemonSet de Capa 4 - L4)
# Procesa el cifrado mTLS/HBONE en cada nodo para la comunicación pod-a-pod.
resource "helm_release" "ztunnel" {
  count      = var.enable_istio ? 1 : 0
  name       = "ztunnel"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "ztunnel"
  version    = "1.22.0"
  namespace  = "istio-system"

  values = [
    yamlencode({
      nodeSelector = { "karpenter.sh/capacity-type" = "spot" }
      priorityClassName = "system-node-critical"
      # Configuración de métricas para ztunnel
      #telemetry = { enabled = true }

      #ztunnel = { env = { CLUSTER_ID = "Kubernetes" } }  # Si usas EKS, fuerza la validación de tokens de servicio nativos
      # Si usas Prometheus Operator, puedes habilitar PodMonitor/ServiceMonitor
      #prometheus = {
      #  podMonitor = {
      #    enabled = true
      #    additionalLabels = { release = "kube-prometheus-stack" }
      #  }
      #}
      resources = {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { cpu = "500m", memory = "512Mi" }
      }
    })
  ]

  depends_on = [helm_release.istiod, helm_release.istio_cni]
}

# PodMonitor para recolectar métricas L4/HBONE del DaemonSet ztunnel
resource "kubectl_manifest" "ztunnel_pod_monitor" {
  count = var.enable_istio ? 1 : 0

  yaml_body = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: PodMonitor
    metadata:
      name: ztunnel
      namespace: istio-system
      labels:
        release: kube-prometheus-stack
    spec:
      selector:
        matchLabels:
          app: ztunnel
      namespaceSelector:
        matchNames:
          - istio-system
      podMetricsEndpoints:
        - port: application-metrics
          interval: 15s
          path: /stats/prometheus
  YAML

  depends_on = [helm_release.ztunnel, helm_release.kube_prometheus_stack]
}

resource "kubectl_manifest" "waypoint_pod_monitor" {
  count = var.enable_istio ? 1 : 0

  yaml_body = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: PodMonitor
    metadata:
      name: istio-waypoint
      namespace: istio-system
      labels:
        release: kube-prometheus-stack
    spec:
      selector:
        matchLabels:
          gateway.networking.k8s.io/gateway-name: waypoint
      namespaceSelector:
        any: true # 🎯 Escanea cualquier namespace donde despliegues un Waypoint
      podMetricsEndpoints:
        - port: http-envoy-prom
          interval: 15s
          path: /stats/prometheus
  YAML

  depends_on = [helm_release.istiod, helm_release.kube_prometheus_stack]
}


# ==============================================================================
# 5. KIALI SERVER & INGRESS CONFIGURATION (VISUALIZACIÓN DE LA MALLA)
# ==============================================================================

# Instalación de Kiali en el clúster
resource "helm_release" "kiali_server" {
  count            = var.enable_istio ? 1 : 0
  name             = "kiali-server"
  repository       = "https://kiali.org/helm-charts"
  chart            = "kiali-server"
  version          = "1.89.0" # Compatible con tu versión de Istio 1.22
  namespace        = "istio-system"
  create_namespace = false

  values = [
    yamlencode({
      auth = { strategy = "anonymous" }# Ideal para laboratorios. Cambiar a 'token' u 'openid' en prod.

      deployment = { nodeSelector = { "karpenter.sh/capacity-type" = "spot" } }# Reutiliza tus nodos spot

      external_services = {
        # 🎯 Enlace directo con el DNS interno de tu kube-prometheus-stack
        prometheus = { url = "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090" }
        grafana = {
          enabled = true
          url     = "https://grafana.aws.rj-engineering.com" # Enlace cruzado nativo en la interfaz
          in_cluster_url = "http://kube-prometheus-stack-grafana.monitoring.svc.cluster.local" # 👈 Para las llamadas del pod de Kiali
          auth = {
            type = "bearer"
            bearer = {
              # Pasamos el valor usando una variable de entrada de Terraform
              token = var.grafana_read_token
            }
          }
        }
        istio = {
          # 🎯 Habilita el soporte explícito para recopilar telemetría L4/L7 de Ambient
          ambient_enabled = true
        }
      }
      server = { port = 20001 }
    })
  ]

  # Asegura que Istio y Prometheus estén listos antes de levantar la interfaz
  depends_on = [helm_release.ztunnel, helm_release.kube_prometheus_stack]
}

# Ingress para exponer la interfaz web de Kiali públicamente a través de NGINX
resource "kubernetes_ingress_v1" "kiali_ingress" {
  count = var.enable_istio ? 1 : 0

  metadata {
    name      = "kiali-ingress"
    namespace = "istio-system"
    annotations = {
      # Reutiliza el emisor SSL Let's Encrypt definido en tu entorno
      "cert-manager.io/cluster-issuer"               = "letsencrypt-${var.environment}"
      "nginx.ingress.kubernetes.io/backend-protocol" = "HTTP"
      "nginx.ingress.kubernetes.io/ssl-redirect"     = "true"
    }
  }

  spec {
    ingress_class_name = "nginx" # Apunta a tu recurso helm_release.nginx_ingress

    tls {
      hosts       = ["kiali.aws.rj-engineering.com"]
      secret_name = "kiali-server-tls-secret"
    }

    rule {
      host = "kiali.aws.rj-engineering.com"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "kiali"
              port {
                number = 20001 # Puerto HTTP interno de Kiali
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.kiali_server, helm_release.nginx_ingress]
}


# 3. Istio Ingress Gateway (Sustituye a Ingress-NGINX y se conecta al NLB de AWS)
/*resource "helm_release" "istio_ingressgateway" {
  count = var.enable_istio ? 1 : 0
  name       = "istio-ingressgateway"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "gateway"
  version    = "1.22.0"
  namespace  = "istio-ingress"
  create_namespace = true

  values = [
    yamlencode({
      service = {
        type = "LoadBalancer"
        annotations = {
          # Integración directa con AWS Load Balancer Controller para crear el NLB físico
          "service.beta.kubernetes.io/aws-load-balancer-type"            = "external"
          "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "instance"
          "service.beta.kubernetes.io/aws-load-balancer-scheme"          = var.nlb_scheme
        }
      }
      resources = {
        requests = { cpu = "200m", memory = "256Mi" }
        limits   = { cpu = "1000m", memory = "1024Mi" }
      }
    })
  ]

  depends_on = [helm_release.istiod, helm_release.aws_lb_controller]
}*/