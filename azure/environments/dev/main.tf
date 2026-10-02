variable "location" {
  type        = string
  description = "Región de Azure donde se desplegarán los recursos"
  default     = "spaincentral"
}

variable "environment" {
  type        = string
  description = "Ambiente (dev, prod, etc.)"
}

variable "vpc_cidr" {
  type        = string
  description = "Espacio de direcciones principal de la VNet"
}

variable "availability_zones" {
  type        = list(string)
  description = "Zonas de disponibilidad (ej. [\"1\", \"2\"])"
  default     = ["1", "2"]
}

variable "on_prem_domain" {
  type    = string
  default = null
}

variable "on_prem_dns_ip" {
  type    = string
  default = null
}

variable "on_prem_public_ip" {
  type    = string
  default = null
}

variable "enable_nat_gateway" {
  type        = bool
  description = "Habilitar NAT Gateway en la red"
}

variable "enable_vpn" {
  type        = bool
  description = "Habilitar la conexión VPN Site-to-Site hacia On-Premises"
}

module "network" {
  source = "../../../modules/network"

  location           = var.location
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones

  on_prem_domain    = var.on_prem_domain
  on_prem_dns_ip    = var.on_prem_dns_ip
  on_prem_public_ip = var.on_prem_public_ip

  enable_nat_gateway = var.enable_nat_gateway
  enable_vpn         = var.enable_vpn
}