data "aws_route53_zone" "main" {
  name         = "rj-engineering.com"
  private_zone = false
}

# 1. Registro Route 53 para la región de España (eu-south-2)
resource "aws_route53_record" "api_es" {
  zone_id = var.route53_zone_id
  name    = "api.rj-engineering.com"
  type    = "A"

  geolocation_routing_policy {
    continent = "EU"
    country   = "ES" # O puedes agrupar por continente
  }

  /*latency_routing_policy {
    region = "eu-south-2" # Región de AWS que evalúa Route 53 para este record
  }*/
  
  set_identifier = "eks-es-region"

  alias {
    name                   = data.kubernetes_service.nginx_ingress_es.status[0].load_balancer[0].ingress[0].hostname
    zone_id                = data.aws_lb.nlb_es.zone_id
    evaluate_target_health = true
  }
}

# 2. Registro Route 53 por defecto / Resto del mundo o Europa central
resource "aws_route53_record" "api_default" {
  zone_id = var.route53_zone_id
  name    = "api.rj-engineering.com"
  type    = "A"

  default_routing_policy {
    # Atiende al resto de peticiones globales que no caigan en la regla específica
  }

  /*latency_routing_policy {
    region = "eu-central-1" # La otra región de AWS
  }*/

  set_identifier = "eks-global-fallback"

  alias {
    name                   = data.kubernetes_service.nginx_ingress_de.status[0].load_balancer[0].ingress[0].hostname
    zone_id                = data.aws_lb.nlb_de.zone_id
    evaluate_target_health = true
  }
}