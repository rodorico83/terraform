# NGINX Ingress Controller
#
# The Service is handed to the AWS Load Balancer Controller via the `external`
# type annotation, which provisions an NLB. LBC also attaches a security group
# to the NLB and opens the matching NodePort on the node SG, so we do not have
# to expose 30000-32767 to the world by hand.
resource "helm_release" "nginx_ingress" {
  count            = var.enable_ingress_nginx ? 1 : 0
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.11.3"
  namespace        = "ingress-nginx"
  create_namespace = true

  /*set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
    value = "external"
  }
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-nlb-target-type"
    value = "instance"
  }
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
    value = var.nlb_scheme
  }

  # instance target type means a second hop through kube-proxy, which SNATs the
  # source address. Local keeps the real client IP and makes the NLB health
  # checks target only nodes actually running a controller pod.
  set {
    name  = "controller.service.externalTrafficPolicy"
    value = "Local"
  }*/

  values = [
    yamlencode({

      # 🎯 1. Etiqueta el Namespace de NGINX para incluirlo en Istio Ambient Mesh
      namespace = {
        labels = {
          "istio.io/dataplane-mode" = "ambient"
          "istio.io/use-waypoint" = "nginx-waypoint"
        }
      }

      controller = {
        # 1. RÉPLICAS FIJAS EN HA
        replicaCount = 1 # Mínimo 2 Pods para soportar actualizaciones sin cortes de red

        # 2. DESACTIVAR EL HPA DE INFRAESTRUCTURA DE SISTEMA 🛑
        autoscaling = {
          enabled = false
        }

        podAnnotations = {
          # Habilita la redirección transparente del tráfico del controller de NGINX al ztunnel
          "ambient.istio.io/redirection" = "enabled"
        }

        # 3. LÍMITES DE RECURSOS ESTRICTOS CONTRA INSTANCIAS SPOT
        resources = {
          requests = {
            cpu    = "200m"
            memory = "256Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "512Mi" # Evita fugas de memoria que ahoguen el nodo
          }
        }

        nodeSelector = { "eks.amazonaws.com/nodegroup" = "private-workers" }

        # 4. DISPERSIÓN OBLIGATORIA (POD ANTI-AFFINITY)
        # Le prohíbe a Kubernetes meter los dos Pods de Ingress en la misma máquina física.
        # Si un nodo Spot de AWS muere, el otro Pod sigue vivo en otro nodo salvando el tráfico.
        affinity = {
          podAntiAffinity = {
            requiredDuringSchedulingIgnoredDuringExecution = [
              {
                labelSelector = {
                  matchExpressions = [
                    {
                      key      = "app.kubernetes.io/name"
                      operator = "In"
                      values   = ["ingress-nginx"]
                    }
                  ]
                }
                topologyKey = "kubernetes.io/hostname"
              }
            ]
          }
        }

        # 5. INTEGRACIÓN DE RED CON EL NLB DE AWS (Capa 1)
        service = {
          externalTrafficPolicy =  "Local"
          annotations = {
            # Le ordena al AWS Load Balancer Controller crear un NLB físico en tus subredes públicas
            "service.beta.kubernetes.io/aws-load-balancer-type"             = "external"
            "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"  = "instance"
            "service.beta.kubernetes.io/aws-load-balancer-scheme"           = var.nlb_scheme
            #"controller.service.externalTrafficPolicy" =  "Local"
          }
        }

        # 6. INTEGRACIÓN CON PROMETEUS, EXPOSICION DE METRICAS RED
        metrics = {
          enabled = true
          port = 10254 # Puerto por donde NGINX expondrá el endpoint /metrics

          # Si usas el Prometheus Operator, Helm puede crearte el PodMonitor/ServiceMonitor automáticamente:
          serviceMonitor = {
            enabled = true
            additionalLabels = {
              release = "kube-prometheus-stack" # Cámbialo por la etiqueta de tu servidor Prometheus
            }
          }
        }
      }
    })
  ]

  depends_on = [helm_release.aws_lb_controller]
}

# ─── EL RECURSO DE LECTURA ASOCIADO ───
# Necesitamos este bloque 'data' para que Terraform lea el estado en tiempo real
# del Service dentro del clúster de Kubernetes una vez que Helm lo crea.
# To read and output the NLB hostname
data "kubernetes_service" "nginx_ingress" {
  #provider = kubernetes.aws_eks
  metadata {
    # Cambia "ingress-nginx-controller" si el Service de tu Helm tiene otro nombre
    name      = "ingress-nginx-controller"

    # Cambia "ingress-nginx" por el namespace real donde instalaste tu Ingress Controller
    namespace = "ingress-nginx"
  }

  depends_on = [helm_release.nginx_ingress]
}



# 1. Definir el Waypoint Gateway para el Namespace de NGINX Ingress
/*resource "kubectl_manifest" "nginx_ingress_waypoint" {
  count = var.enable_ingress_nginx && var.enable_istio ? 1 : 0

  yaml_body = <<-YAML
    apiVersion: gateway.networking.k8s.io/v1
    kind: Gateway
    metadata:
      name: nginx-waypoint
      namespace: ingress-nginx
      annotations:
        argocd.argoproj.io/sync-wave: "-4"
    spec:
      gatewayClassName: istio-waypoint
      listeners:
        - name: mesh
          port: 15008
          protocol: HBONE
  YAML

  depends_on = [
    helm_release.nginx_ingress,
    helm_release.istiod,
    kubectl_manifest.gateway_api_install
  ]
}*/

