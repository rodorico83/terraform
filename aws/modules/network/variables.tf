variable "aws_region" {
  type    = string
  default = "eu-south-2"
}

variable "environment" {
  type        = string
  description = "Environment name (e.g. dev, prod)"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC"
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  type        = list(string)
  description = "List of availability zones"
  default     = ["eu-south-2a", "eu-south-2b", "eu-south-2c"]
}

variable "enable_nat_gateway" {
  type        = bool
  description = "Enable NAT"
  default     = true
}


variable "single_nat_gateway" {
  type        = bool
  description = "Should be true if you want to provision a single shared NAT Gateway across all private networks (ideal for non-prod)"
  default     = false
}

variable "one_nat_gateway_per_az" {
  type        = bool
  description = "Should be true if you want one NAT Gateway per availability zone (production grade)"
  default     = true
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
