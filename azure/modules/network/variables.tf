variable "environment" {
  type        = string
  description = "Environment name (e.g. dev, prod)"
}

variable "location" {
  type        = string
  description = "Azure region location"
  default     = "Spain Central"
}

variable "vpc_cidr" {
  type        = string
  description = "Address space for the Virtual Network"
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  type        = list(string)
  description = "List of availability zones"
  default     = ["1", "2", "3"]
}

variable "enable_vpn" {
  type        = bool
  description = "Enable site-to-site VPN connection"
  default     = true
}

variable "on_prem_cidr" {
  type        = string
  description = "On-premises network CIDR block"
  default     = "192.168.0.0/16"
}

variable "on_prem_public_ip" {
  type        = string
  default     = null
  description = "Public IP address of the on-premises customer gateway. Obligatorio cuando enable_vpn = true."
}

variable "on_prem_domain" {
  type        = string
  description = "Domain/Subdomain of the on-premises customer network"
}

variable "on_prem_dns_ip" {
  type        = string
  description = "IP address of the on-premises DNS server"
  default     = "192.168.1.10"
}