# Parcheamos el ConfigMap de CoreDNS dentro de AKS para enviar las peticiones
# del dominio On-Premises directamente por la VPN hacia el servidor DNS local en entornos Non-Prod.
resource "kubernetes_config_map_v1_data" "coredns_custom" {
  count = (var.vnet.enable_vpn && var.environment != "prod") ? 1 : 0

  metadata {
    name      = "coredns"
    namespace = "kube-system"
  }

  # Forzamos a Terraform a aplicar el bloque personalizado dentro del Corefile
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

      # ─── BLOQUE DE REENVÍO DIRECTO ON-PREMISES (NON-PROD) ───
      # Redirige las consultas del subdominio de la oficina al DNS local vía VPN
      ${var.premises.on_prem_domain}:53 {
          errors
          cache 30
          forward . ${var.premises.on_prem_dns_ip}
      }
    EOT
  }

  depends_on = [
    azurerm_kubernetes_cluster.main
  ]
}