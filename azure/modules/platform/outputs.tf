# Outputs del clúster de Kubernetes (AKS)
output "eks" {
  description = "Metadatos del clúster AKS agrupados en un solo objeto (equivalente a EKS)."
  value = {
    id              = azurerm_kubernetes_cluster.main.id
    name            = azurerm_kubernetes_cluster.main.name
    endpoint        = azurerm_kubernetes_cluster.main.kube_config[0].host
    cert            = azurerm_kubernetes_cluster.main.kube_config[0].cluster_ca_certificate
    node_group_name = azurerm_kubernetes_cluster.main.default_node_pool[0].name
    node_group_arn  = azurerm_kubernetes_cluster.main.default_node_pool[0].id
    oidc_url        = azurerm_kubernetes_cluster.main.oidc_issuer_url
    identity_pid    = azurerm_kubernetes_cluster.main.identity[0].principal_id
  }
}

# Outputs de la Base de Datos PostgreSQL (db)
output "db" {
  description = "Metadatos de la base de datos PostgreSQL agrupados en un solo objeto."
  value = {
    id                   = azurerm_postgresql_flexible_server.postgres.id
    name                 = azurerm_postgresql_flexible_server_database.postgres.name
    port                 = var.db_config.port
    endpoint             = azurerm_postgresql_flexible_server.postgres.fqdn
    server_name          = azurerm_postgresql_flexible_server.postgres.name
    admin_username       = azurerm_postgresql_flexible_server.postgres.administrator_login
    nsg_id               = azurerm_network_security_group.db.id
    private_dns_zone_id  = azurerm_private_dns_zone.postgres.id
  }
  sensitive = true
}

# Outputs de Almacenamiento (storage)
output "storage" {
  description = "Metadatos de las cuentas de almacenamiento y contenedores/shares."
  value = {
    blob_storage_account_name = azurerm_storage_account.app_data.name
    blob_container_name       = azurerm_storage_container.app_bucket.name
    file_share_account_name   = azurerm_storage_account.efs_equivalent.name
    file_share_name           = azurerm_storage_share.shared_data.name
    workload_identity_id      = azurerm_user_assigned_identity.orders_service.id
    workload_identity_client  = azurerm_user_assigned_identity.orders_service.client_id
  }
}