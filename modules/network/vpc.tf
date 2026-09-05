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

  tags = local.common_tags
}
