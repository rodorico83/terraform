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

  set {
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
  }

  depends_on = [helm_release.aws_lb_controller]
}


