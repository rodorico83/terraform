resource "aws_security_group" "route53_resolver_outbound" {
  count       = var.enable_vpn ? 1 : 0
  name        = "route53-resolver-outbound-sg"
  description = "Allow outbound DNS forwarding to on-premises resolvers"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [var.on_prem_cidr]
  }

  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [var.on_prem_cidr]
  }

  tags = local.common_tags
}

resource "aws_route53_resolver_endpoint" "outbound" {
  count     = var.enable_vpn ? 1 : 0
  name      = "outbound-dns"
  direction = "OUTBOUND"

  security_group_ids = [aws_security_group.route53_resolver_outbound[0].id]

  ip_address { subnet_id = module.vpc.private_subnets[0] }
  ip_address { subnet_id = module.vpc.private_subnets[1] }

  tags = local.common_tags
}

resource "aws_route53_resolver_rule" "to_on_prem" {
  count                = var.enable_vpn ? 1 : 0
  domain_name          = "onprem.internal"
  name                 = "forward-to-onprem"
  rule_type            = "FORWARD"
  resolver_endpoint_id = aws_route53_resolver_endpoint.outbound[0].id

  target_ip {
    ip = var.on_prem_dns_ip
  }

  tags = local.common_tags
}

resource "aws_route53_resolver_rule_association" "vpc_assoc" {
  count            = var.enable_vpn ? 1 : 0
  resolver_rule_id = aws_route53_resolver_rule.to_on_prem[0].id
  vpc_id           = module.vpc.vpc_id
}
