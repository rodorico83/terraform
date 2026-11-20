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

  values = [
    yamlencode({

      # 🎯 1. Etiqueta el Namespace de NGINX para incluirlo en Istio Ambient Mesh
      namespace = {
        labels = {
          "istio.io/dataplane-mode" = "ambient"
          #"istio.io/use-waypoint" = "nginx-waypoint"
        }
      }

      controller = {
        # 1. RÉPLICAS FIJAS EN HA
        replicaCount = 1 # Mínimo 2 Pods para soportar actualizaciones sin cortes de red

        # 2. DESACTIVAR EL HPA DE INFRAESTRUCTURA DE SISTEMA 🛑
        autoscaling = { enabled = false }

        # Habilita la redirección transparente del tráfico del controller de NGINX al ztunnel
        podAnnotations = { "ambient.istio.io/redirection" = "enabled" }

        # 3. LÍMITES DE RECURSOS ESTRICTOS CONTRA INSTANCIAS SPOT
        resources = {
          requests = {
            cpu    = "100m"
            memory = "128Mi"
          }
          limits = {
            cpu    = "200m"
            memory = "256Mi" # Evita fugas de memoria que ahoguen el nodo
          }
        }

        readinessProbe = {
          httpGet = {
            path   = "/healthz"
            port   = 10254
            scheme = "HTTP"
          }
          initialDelaySeconds = 10
          periodSeconds       = 10
          timeoutSeconds      = 1
          successThreshold    = 1
          failureThreshold    = 3
        }

        livenessProbe = {
          httpGet = {
            path   = "/healthz"
            port   = 10254
            scheme = "HTTP"
          }
          initialDelaySeconds = 10
          periodSeconds       = 10
          timeoutSeconds      = 1
          successThreshold    = 1
          failureThreshold    = 3
        }

        nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
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
          # NLB target group, send traffic only to nodes with ngnix pods, keeps Client IP
          # Cluster option send to all target group nodes of NLB, SNAT (Source Network Address Translation)
          externalTrafficPolicy =  "Local"
          annotations = {
            # Use external AWS load balancer
            "service.beta.kubernetes.io/aws-load-balancer-type"             = "external"
            # NLB envía el tráfico al puerto de nodo (NodePort) instead of Pod port (VPC CNI pod ENI)
            "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"  = "instance"  # "ip" in case of using pod ENI
            # Place NLB in public subnet with public IP, other option internal for private subnet
            "service.beta.kubernetes.io/aws-load-balancer-scheme"           = "internet-facing"
            #"controller.service.externalTrafficPolicy" =  "Local"
          }
        }

        # 6. INTEGRACIÓN CON PROMETEUS, EXPOSICION DE METRICAS RED
        metrics = {
          enabled = true
          port = 10254 # Puerto por donde NGINX expondrá el endpoint /metrics

          # Si usas el Prometheus Operator, Helm puede crearte el PodMonitor/ServiceMonitor automáticamente:
          # Cuando creando de cero comentar ya que prometeus stack depende de ingress-nginx y fallara por CRD no disponible
          serviceMonitor = {
            enabled = true
            additionalLabels = { release = "kube-prometheus-stack" }
          }
        }
      }
    })
  ]
  depends_on = [helm_release.aws_lb_controller,kubectl_manifest.karpenter_node_pool_infra]
}

# ─── EL RECURSO DE LECTURA ASOCIADO ───
# Necesitamos este bloque 'data' para que Terraform lea el estado en tiempo real
# del Service dentro del clúster de Kubernetes una vez que Helm lo crea.
# To read and output the NLB hostname
data "kubernetes_service" "nginx_ingress" {
  #provider = kubernetes.aws_eks
  metadata {
    name      = "ingress-nginx-controller"
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

