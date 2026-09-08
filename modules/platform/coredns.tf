# Parcheamos el CoreDNS de EKS para saltarnos Route 53 Resolver y ahorrar $182/mes
resource "kubernetes_config_map_v1_data" "coredns_custom" {
  count = (var.vpc.enable_vpn && var.environment != "prod") ? 1 : 0
  provider = kubernetes.aws_eks # Se ejecuta en tu clúster EKS

  metadata {
    name      = "coredns"
    namespace = "kube-system"
  }

  # Forzamos a Terraform a sobreescribir el Corefile nativo
  force = true

  data = {
    Corefile = <<-EOT
      .:53 {
          errors
          health {
             lameduck 5s
          }
          ready
          kubernetes cluster.local in-addr.arpa ip6.arpa {
             pods insecure
             fallthrough in-addr.arpa ip6.arpa
             ttl 30
          }
          prometheus :9153
          forward . /etc/resolv.conf
          cache 30
          loop
          reload
          loadbalance
      }

      # ─── EL BLOQUE DE AHORRO PARA ENTORNO DE DESARROLLO ───
      # Cada vez que un Pod intente buscar un servidor de tu oficina,
      # CoreDNS enviará la petición directamente por la VPN al servidor local
      ${var.on_prem_domain}:53 {
          errors
          cache 30
          forward . ${var.on_prem_dns_ip}
          reload
      }
    EOT
  }

  # Asegura que CoreDNS se parchee solo cuando los nodos y EKS estén 100% operativos
  depends_on = [aws_eks_node_group.private_nodes]
}