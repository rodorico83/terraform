output "vnet" {
  description = "Key Azure Virtual Network attributes grouped into a single object."
  value = {
    id                  = azurerm_virtual_network.vnet.id
    cidr                = azurerm_virtual_network.vnet.address_space[0]
    name                = azurerm_virtual_network.vnet.name
    public_subnet_ids   = azurerm_subnet.public[*].id
    private_subnet_ids  = azurerm_subnet.private[*].id
    database_subnet_ids = azurerm_subnet.database[*].id
    on_prem_cidr        = var.on_prem_cidr
    on_prem_dns_ip      = var.on_prem_dns_ip
    on_prem_domain      = var.on_prem_domain
    enable_vpn          = var.enable_vpn
  }
}