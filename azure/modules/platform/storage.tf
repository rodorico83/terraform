# ==============================================================================
# 1. EBS EQUIVALENT: BLOCK STORAGE (Azure Disk CSI Driver)
# ==============================================================================
# En AKS, el driver `disk.csi.azure.com` viene preinstalado de forma nativa.
# Definimos la clase de almacenamiento predeterminada del clúster (Premium SSD / Premium_LRS).

resource "kubernetes_storage_class_v1" "managed_csi_default" {
  metadata {
    name = "managed-csi-premium"
    annotations = {
      # Marca esta StorageClass como la predeterminada del clúster (al igual que gp3 en AWS)
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "disk.csi.azure.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer" # Optimiza costes: aprisiona cuando el Pod arranca
  allow_volume_expansion = true

  parameters = {
    skuName = "Premium_LRS" # Discos SSD Premium de alto rendimiento y cifrados por defecto
  }

  depends_on = [
    azurerm_kubernetes_cluster.main
  ]
}


# ==============================================================================
# 2. EFS EQUIVALENT: SHARED FILE SYSTEM (Azure Files + Azure File CSI)
# ==============================================================================
# En AWS se utilizaba EFS con Mount Targets y un EKS Add-on dedicado.
# En Azure, el equivalente nativo es Azure Files (Storage Share) a través del 
# driver preinstalado `file.csi.azure.com`.

# Cuenta de almacenamiento para archivos compartidos (EFS equivalent)
resource "azurerm_storage_account" "efs_equivalent" {
  name                     = "${replace(var.environment, "-", "")}sharedfilesa"
  resource_group_name      = var.vnet.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = var.environment == "prod" ? "ZRS" : "LRS"

  # Acceso privado por red VNet
  public_network_access_enabled = true

  tags = local.common_tags
}

# File Share en Azure (equivalente a aws_efs_file_system)
resource "azurerm_storage_share" "shared_data" {
  name                 = "${var.environment}-shared-efs"
  storage_account_id   = azurerm_storage_account.efs_equivalent.id
  quota                = 100 # Tamaño inicial en GB
}

# StorageClass de Kubernetes para Azure Files (equivalente a efs-sc)
resource "kubernetes_storage_class_v1" "azurefile_sc" {
  metadata {
    name = "azurefile-csi"
  }

  storage_provisioner    = "file.csi.azure.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "Immediate"
  allow_volume_expansion = true

  parameters = {
    skuName = "Standard_LRS"
  }

  depends_on = [
    azurerm_kubernetes_cluster.main
  ]
}


# ==============================================================================
# 3. S3 EQUIVALENT: OBJECT STORAGE (Azure Blob Storage + Workload Identity)
# ==============================================================================
# Reemplaza aws_s3_bucket, políticas de acceso público, cifrado y asumición de roles OIDC.

# 1. Cuenta de almacenamiento de objetos (Blob Storage)
resource "azurerm_storage_account" "app_data" {
  name                     = "${replace(var.environment, "-", "")}appdatas3sa"
  resource_group_name      = var.vnet.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = var.environment == "prod" ? "GRS" : "LRS"

  # Bloqueo de acceso público explícito (equivalente a aws_s3_bucket_public_access_block)
  public_network_access_enabled = true

  blob_properties {
    versioning_enabled = true
  }

  tags = local.common_tags
}

# 2. Contenedor de Blobs (equivalente al Bucket S3 principal)
resource "azurerm_storage_container" "app_bucket" {
  name                  = "orders-service-data"
  storage_account_name  = azurerm_storage_account.app_data.name
  container_access_type = "private" # Acceso estrictamente privado
}

# 3. Identidad Administrada de Usuario para la aplicación "orders-service"
# Reemplaza al rol IAM (aws_iam_role) y a la política IRSA con OIDC
resource "azurerm_user_assigned_identity" "orders_service" {
  name                = "${var.environment}-orders-service-identity"
  location            = var.location
  resource_group_name = var.vnet.resource_group_name

  tags = local.common_tags
}

# 4. Credencial de Identidad Federada (AKS Workload Identity)
# Reemplaza la condición de assume_role_policy para la ServiceAccount 'orders-sa'
resource "azurerm_federated_identity_credential" "orders_service" {
  name                = "${var.environment}-orders-service-federated"
  resource_group_name = var.vnet.resource_group_name
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject             = "system:serviceaccount:default:orders-sa" # namespace:serviceaccount
  parent_id           = azurerm_user_assigned_identity.orders_service.id
}

# 5. Asignación de rol de permisos RBAC sobre el contenedor/bucket
# Equivalente a aws_iam_policy (s3:PutObject, s3:GetObject, s3:DeleteObject)
resource "azurerm_role_assignment" "orders_s3_blob_contributor" {
  scope                = azurerm_storage_account.app_data.id
  role_definition_name = "Storage Blob Data Contributor" # Otorga lectura/escritura/borrado de blobs
  principal_id         = azurerm_user_assigned_identity.orders_service.principal_id
}