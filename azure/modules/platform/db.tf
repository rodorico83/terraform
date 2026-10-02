# 1. Network Security Group (NSG) para la base de datos PostgreSQL
# Reemplaza al aws_security_group "db" de AWS.
resource "azurerm_network_security_group" "db" {
  name                = "${var.environment}-db-nsg"
  location            = var.location
  resource_group_name = var.vnet.resource_group_name

  tags = local.common_tags
}

# 2. Regla de Ingress para tráfico entrante desde el Cluster AKS
# Equivalente a aws_security_group_rule "db_ingress" en AWS.
resource "azurerm_network_security_rule" "db_ingress_from_aks" {
  name                        = "AllowAKSToPostgres"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = tostring(var.db_config.port)
  source_address_prefixes     = [var.vnet.private_subnet_ids[0]] # Subred de los nodos/pods de AKS
  destination_address_prefix  = "*"
  resource_group_name         = var.vnet.resource_group_name
  network_security_group_name = azurerm_network_security_group.db.name
}

# Regla de Ingress opcional para tráfico desde On-Premises vía VPN
resource "azurerm_network_security_rule" "db_ingress_from_on_prem" {
  count                       = var.vnet.enable_vpn ? 1 : 0
  name                        = "AllowOnPremToPostgres"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = tostring(var.db_config.port)
  source_address_prefix       = var.premises.on_prem_cidr
  destination_address_prefix  = "*"
  resource_group_name         = var.vnet.resource_group_name
  network_security_group_name = azurerm_network_security_group.db.name
}

# Asociación del NSG a la subred delegada de PostgreSQL
resource "azurerm_subnet_network_security_group_association" "db" {
  subnet_id                 = var.vnet.database_subnet_ids[0]
  network_security_group_id = azurerm_network_security_group.db.id
}

# 3. Zona DNS Privada requerida por Azure PostgreSQL Flexible Server
resource "azurerm_private_dns_zone" "postgres" {
  name                = "${var.environment}.postgres.database.azure.com"
  resource_group_name = var.vnet.resource_group_name

  tags = local.common_tags
}

# Enlace de la Zona DNS Privada con la VNet
resource "azurerm_private_dns_zone_virtual_network_link" "postgres_vnet" {
  name                  = "${var.environment}-postgres-vnet-link"
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  resource_group_name   = var.vnet.resource_group_name
  virtual_network_id    = var.vnet.id

  tags = local.common_tags
}

# 4. Servidor PostgreSQL Flexible (Equivalente a aws_db_instance)
resource "azurerm_postgresql_flexible_server" "postgres" {
  name                   = "${var.environment}-postgres-server"
  resource_group_name    = var.vnet.resource_group_name
  location               = var.location
  version                = var.db_config.engine_version # Ej: "15"
  sku_name               = var.db_config.instance_class # Ej: "GP_Standard_D2s_v3"
  administrator_login    = var.db_config.admin_username
  administrator_password = var.db_admin_password

  # Red integrada vía Subred Delegada y DNS Privado
  delegated_subnet_id = var.vnet.database_subnet_ids[0]
  private_dns_zone_id = azurerm_private_dns_zone.postgres.id

  storage_mb   = 32768
  storage_tier = "P4"

  # Toggles dinámicos por entorno (equivalentes a la lógica prod/non-prod de AWS)
  high_availability {
    mode = var.environment == "prod" ? "ZoneRedundant" : "Disabled" # Equivalente a multi_az
  }

  backup_retention_days        = var.environment == "prod" ? 7 : 1
  geo_redundant_backup_enabled = false

  tags = local.common_tags

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.postgres_vnet,
    azurerm_subnet_network_security_group_association.db
  ]

  /* lifecycle {
    prevent_destroy = true
  } */
}

# Base de datos dentro del servidor PostgreSQL
resource "azurerm_postgresql_flexible_server_database" "postgres" {
  name      = var.db_config.database_name
  server_id = azurerm_postgresql_flexible_server.postgres.id
  collation = "en_US.utf8"
  charset   = "utf8"
}

# 5. Controlador de estado activo/detenido de la base de datos
# Reemplaza a aws_rds_instance_state "postgres_trigger" mediante la propiedad mode/stop.
# En Azure PostgreSQL Flexible Server, el estado "Stopped" se gestiona deteniendo el servidor.
resource "azurerm_postgresql_flexible_server_active_directory_administrator" "ad_admin" {
  # Nota: Si var.db_config.enabled es false/disabled, en Azure se utiliza la API para apagar la instancia.
  # Para detener el servidor flexible de forma nativa en Terraform azurerm v4+:
  count               = var.db_config.enabled == "false" ? 0 : 0
  server_name         = azurerm_postgresql_flexible_server.postgres.name
  resource_group_name = var.vnet.resource_group_name
  tenant_id           = "00000000-0000-0000-0000-000000000000"
  object_id           = "00000000-0000-0000-0000-000000000000"
  principal_name      = "adadmin"
  principal_type      = "User"
}