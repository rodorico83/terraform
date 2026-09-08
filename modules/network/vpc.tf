locals {
  common_tags = {
    ManagedBy   = "Terraform"
    Environment = var.environment
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "main-vpc"
  cidr = var.vpc_cidr
  azs  = var.availability_zones

  # Dynamic subnet layout
  public_subnets = [
    for index in range(length(var.availability_zones)) :
    cidrsubnet(var.vpc_cidr, 4, index)
  ]

  private_subnets = [
    for index in range(length(var.availability_zones)) :
    cidrsubnet(var.vpc_cidr, 4, index + 4)
  ]

  database_subnets = [
    for index in range(length(var.availability_zones)) :
    cidrsubnet(var.vpc_cidr, 4, index + 8)
  ]

  create_database_subnet_group           = true
  create_database_subnet_route_table     = true
  create_database_internet_gateway_route = false

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = var.one_nat_gateway_per_az

  # 🚀 Native VPN capabilities in VPC module:
  enable_vpn_gateway                 = var.enable_vpn
  propagate_private_route_tables_vgw = var.enable_vpn

  customer_gateways = var.enable_vpn ? {
    on_prem = {
      bgp_asn    = 65000
      ip_address = var.on_prem_public_ip
    }
  } : {}

  # Requerido por el AWS Load Balancer Controller para descubrir donde colocar
  # los NLB/ALB. Sin estos tags el provisioning falla con "could not find any
  # suitable subnets for creating the load balancer".
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"

  }

  tags = local.common_tags
}
