variable "aws_region" {
  type    = string
  default = "eu-south-2"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "vpc_cidr" {
  type    = string
  default = "10.100.0.0/16"
}

variable "on_prem_domain" {
  type = string
}

variable "on_prem_dns_ip" {
  type = string
}

variable "on_prem_public_ip" {
  type    = string
  default = null
}

variable "availability_zones" {
  type    = list(string)
  default = ["eu-south-2a", "eu-south-2b", "eu-south-2c"]
}

module "network" {
  source                 = "../../../modules/network"
  on_prem_domain         = var.on_prem_domain
  on_prem_dns_ip         = var.on_prem_dns_ip
  on_prem_public_ip      = var.on_prem_public_ip
  environment            = var.environment
  vpc_cidr               = var.vpc_cidr
  availability_zones     = var.availability_zones
  single_nat_gateway     = false # Production HA: dedicated NAT per AZ
  one_nat_gateway_per_az = true
  enable_vpn             = true
}
