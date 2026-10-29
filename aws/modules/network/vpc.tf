module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.environment}-vpc"
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

  enable_nat_gateway     = var.enable_nat_gateway
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = var.one_nat_gateway_per_az

  # 🎯 REQUERIDO PARA RESOLUCIÓN DE DNS PRIVADO EN VPC ENDPOINTS
  #enable_dns_hostnames = true
  #enable_dns_support   = true

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
  public_subnet_tags = { "kubernetes.io/role/elb" = "1" }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }

  tags = local.common_tags
}

/*
# 1. Security Group para el VPC Endpoint
resource "aws_security_group" "sts_endpoint" {
  name        = "${var.environment}-sts-endpoint-sg"
  description = "Security group for STS Interface VPC Endpoint"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "HTTPS from VPC subnets"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.environment}-sts-endpoint-sg"
  })
}

# 2. Recurso Interface Endpoint para STS
resource "aws_vpc_endpoint" "sts" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.sts" # Ajusta a la región correspondiente si usas una variable
  vpc_endpoint_type = "Interface"

  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.sts_endpoint.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.environment}-sts-vpc-endpoint"
  })
}*/