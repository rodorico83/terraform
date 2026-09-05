# 1. Customer Gateway
resource "aws_customer_gateway" "on_prem" {
  count      = var.enable_vpn ? 1 : 0
  bgp_asn    = 65000
  ip_address = var.on_prem_public_ip
  type       = "ipsec.1"
  tags       = merge(local.common_tags, { Name = "customer-gw" })
}

# 2. AWS VPN Gateway
resource "aws_vpn_gateway" "vpn" {
  count  = var.enable_vpn ? 1 : 0
  vpc_id = module.vpc.vpc_id
  tags   = merge(local.common_tags, { Name = "vpn-gw" })
}

# 3. Site-to-Site VPN Connection
resource "aws_vpn_connection" "main" {
  count               = var.enable_vpn ? 1 : 0
  vpn_gateway_id      = aws_vpn_gateway.vpn[0].id
  customer_gateway_id = aws_customer_gateway.on_prem[0].id
  type                = "ipsec.1"
  static_routes_only  = true
  tags                = merge(local.common_tags, { Name = "onprem-vpn" })
}

# 4. VPN Connection Static Route
resource "aws_vpn_connection_route" "on_prem_traffic" {
  count                  = var.enable_vpn ? 1 : 0
  destination_cidr_block = var.on_prem_cidr
  vpn_connection_id      = aws_vpn_connection.main[0].id
}

# 5. Route Table Propagation
resource "aws_route" "private_to_on_prem" {
  count                  = var.enable_vpn ? length(var.availability_zones) : 0
  route_table_id         = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block = var.on_prem_cidr
  gateway_id             = aws_vpn_gateway.vpn[0].id
}
