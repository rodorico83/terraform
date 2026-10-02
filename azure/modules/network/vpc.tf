resource "azurerm_resource_group" "main" {
  name     = "${var.environment}-network-rg"
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_virtual_network" "vnet" {
  name                = "${var.environment}-vnet"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.vpc_cidr]
  tags                = local.common_tags
}

# Public Subnets (dynamically allocated)
resource "azurerm_subnet" "public" {
  count                = length(var.availability_zones)
  name                 = "public-subnet-${count.index + 1}"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [cidrsubnet(var.vpc_cidr, 4, count.index)]
}

# Private Subnets
resource "azurerm_subnet" "private" {
  count                = length(var.availability_zones)
  name                 = "private-subnet-${count.index + 1}"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [cidrsubnet(var.vpc_cidr, 4, count.index + 4)]
}

# Database Subnets
resource "azurerm_subnet" "database" {
  count                = length(var.availability_zones)
  name                 = "database-subnet-${count.index + 1}"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [cidrsubnet(var.vpc_cidr, 4, count.index + 8)]
}

# Gateway Subnet (Required for Azure VPN Gateway)
resource "azurerm_subnet" "gateway" {
  count                = var.enable_vpn ? 1 : 0
  name                 = "GatewaySubnet" # Fixed name required by Azure
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [cidrsubnet(var.vpc_cidr, 4, 12)]
}

# Outbound DNS Resolver Subnet
resource "azurerm_subnet" "dns_outbound" {
  count                = (var.enable_vpn && var.environment == "prod") ? 1 : 0
  name                 = "snet-dns-outbound"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [cidrsubnet(var.vpc_cidr, 4, 13)]

  delegation {
    name = "Microsoft.Network.dnsResolvers"
    service_delegation {
      name    = "Microsoft.Network/dnsResolvers"
      actions = ["Microsoft.Network/dnsResolvers/subnets/write"]
    }
  }
}