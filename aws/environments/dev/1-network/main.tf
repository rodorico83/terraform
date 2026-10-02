variable "aws_region" {
  type    = string
  default = "eu-south-2"
}

variable "availability_zones" {
  type    = list(string)
  default = ["eu-south-2a", "eu-south-2b"]
}


variable "environment" {
  type    = string
}

variable "vpc_cidr" {
  type    = string
}

variable "on_prem_domain" {
  type = string
  default = null
}

variable "on_prem_dns_ip" {
  type = string
  default = null
}

variable "on_prem_public_ip" {
  type    = string
  default = null
}

variable "enable_nat_gateway" {
  type        = bool
  description = "Enable NAT"

}

variable "enable_vpn" {
  type    = bool
  description = "Enable VPP AWS - OnPremises"
}

module "network" {
  source = "../../../modules/network"

  on_prem_domain         = var.on_prem_domain
  on_prem_dns_ip         = var.on_prem_dns_ip
  on_prem_public_ip      = var.on_prem_public_ip
  environment            = var.environment
  vpc_cidr               = var.vpc_cidr
  availability_zones     = var.availability_zones
  single_nat_gateway     = true # Cost optimization for dev: single shared NAT
  enable_nat_gateway     = var.enable_nat_gateway
  one_nat_gateway_per_az = false
  enable_vpn             = var.enable_vpn # Toggle as needed

}
