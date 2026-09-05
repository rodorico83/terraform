# Este ConfigMap se creará en AWS EKS
resource "kubernetes_config_map" "db_config_aws" {
  provider = kubernetes.aws_eks # <--- Fuerza a usar el proveedor de AWS
  metadata {
    name = "database-metadata"
  }
  data = {
    DATABASE_ENDPOINT = aws_db_instance.postgres.address
    DATABASE_PORT     = tostring(var.db_config.port)
    DATABASE_NAME     = var.db_config.database_name
  }
}

# Este ConfigMap se creará en su infraestructura LOCAL
resource "kubernetes_config_map" "db_config_local" {
  provider = kubernetes.on_premises # <--- Fuerza a usar el proveedor Local
  metadata {
    name = "database-metadata"
  }
  data = {
    DATABASE_ENDPOINT = aws_db_instance.postgres.address
    DATABASE_PORT     = tostring(var.db_config.port)
    DATABASE_NAME     = var.db_config.database_name
  }
  # (¡Gracias a la VPN, su clúster local podrá leer este endpoint e interconectarse!)
}