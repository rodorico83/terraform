output "nginx_ingress_nlb_dns" {
  description = "Nginx Ingress NLB Hostname"
  value       = data.kubernetes_service.nginx_ingress.status[0].load_balancer[0].ingress[0].hostname
}

