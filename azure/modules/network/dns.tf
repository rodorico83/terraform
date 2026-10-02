# Private DNS Resolver
resource "azurerm_private_dns_resolver" "main" {
  count               = (var.enable_vpn && var.environment == "prod") ? 1 : 0
  name                = "dns-resolver"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  virtual_network_id  = azurerm_virtual_network.vnet.id

  tags = local.common_tags
}

# Outbound DNS Endpoint
resource "azurerm_private_dns_resolver_outbound_endpoint" "outbound" {
  count                   = (var.enable_vpn && var.environment == "prod") ? 1 : 0
  name                    = "outbound-dns-ep"
  private_dns_resolver_id = azurerm_private_dns_resolver.main[0].id
  location                = azurerm_resource_group.main.location
  subnet_id               = azurerm_subnet.dns_outbound[0].id

  tags = local.common_tags
}

# Forwarding Ruleset
resource "azurerm_private_dns_resolver_dns_forwarding_ruleset" "ruleset" {
  count                                           = (var.enable_vpn && var.environment == "prod") ? 1 : 0
  name                                            = "forward-to-onprem-ruleset"
  resource_group_name                             = azurerm_resource_group.main.name
  location                                        = azurerm_resource_group.main.location
  private_dns_resolver_outbound_endpoint_ids     = [azurerm_private_dns_resolver_outbound_endpoint.outbound[0].id]

  tags = local.common_tags
}

# DNS Forwarding Rule (Targeting On-Prem DNS Server)
resource "azurerm_private_dns_resolver_forwarding_rule" "to_on_prem" {
  count                     = (var.enable_vpn && var.environment == "prod") ? 1 : 0
  name                      = "forward-to-onprem"
  dns_forwarding_ruleset_id = azurerm_private_dns_resolver_dns_forwarding_ruleset.ruleset[0].id
  domain_name               = "${var.on_prem_domain}."
  enabled                   = true

  target_dns_servers {
    ip_address = var.on_prem_dns_ip
    port       = 53
  }
}

# Link DNS Forwarding Ruleset to Virtual Network
resource "azurerm_private_dns_resolver_vnet_link" "vnet_assoc" {
  count                     = var.enable_vpn ? 1 : 0
  name                      = "vnet-dns-assoc"
  dns_forwarding_ruleset_id = azurerm_private_dns_resolver_dns_forwarding_ruleset.ruleset[0].id
  virtual_network_id        = azurerm_virtual_network.vnet.id
}