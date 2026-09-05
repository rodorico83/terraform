variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "availability_zones" {
  type    = list(string)
  default = ["eu-west-1a", "eu-west-1b"]
}

module "network" {
  source = "../../../modules/network"

  environment            = var.environment
  vpc_cidr               = var.vpc_cidr
  availability_zones     = var.availability_zones
  single_nat_gateway     = true # Cost optimization for dev: single shared NAT
  one_nat_gateway_per_az = false
  enable_vpn             = false # Toggle as needed
}
