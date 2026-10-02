check "vpn_requires_customer_gateway_ip" {
  assert {
    condition     = !var.enable_vpn || try(length(trimspace(var.on_prem_public_ip)) > 0, false)
    error_message = "enable_vpn = true requiere on_prem_public_ip con la IP publica real del customer gateway."
  }
}

# Azure Gateway Public IP
resource "azurerm_public_ip" "vpn_gw" {
  count               = var.enable_vpn ? 1 : 0
  name                = "${var.environment}-vnet-gw-ip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

# Azure Virtual Network Gateway
resource "azurerm_virtual_network_gateway" "main" {
  count               = var.enable_vpn ? 1 : 0
  name                = "${var.environment}-vnet-gw"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  type     = "Vpn"
  vpn_type = "RouteBased"
  active_active = false
  enable_bgp    = false
  sku           = "VpnGw1"

  ip_configuration {
    name                          = "vnetGatewayConfig"
    public_ip_address_id          = azurerm_public_ip.vpn_gw[0].id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.gateway[0].id
  }

  tags = local.common_tags
}

# Local Network Gateway (On-Premises Gateway Equivalent)
resource "azurerm_local_network_gateway" "on_prem" {
  count               = var.enable_vpn ? 1 : 0
  name                = "on-prem-gateway"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  gateway_address     = var.on_prem_public_ip
  address_space       = [var.on_prem_cidr]

  tags = merge(local.common_tags, { Name = "customer-gw" })
}

# Site-to-Site VPN Connection
resource "azurerm_virtual_network_gateway_connection" "on_prem" {
  count                      = var.enable_vpn ? 1 : 0
  name                       = "onprem-vpn-connection"
  location                   = azurerm_resource_group.main.location
  resource_group_name        = azurerm_resource_group.main.name
  type                       = "IPsec"
  virtual_network_gateway_id = azurerm_virtual_network_gateway.main[0].id
  local_network_gateway_id   = azurerm_local_network_gateway.on_prem[0].id

  shared_key = "Use-A-Secure-Shared-Key-Here"
  tags       = merge(local.common_tags, { Name = "onprem-vpn" })
}