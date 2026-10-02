# 1. Network Security Group para la subred de los Nodos de AKS
resource "azurerm_network_security_group" "aks" {
  name                = "${var.environment}-aks-nsg"
  location            = var.location
  resource_group_name = var.vnet.resource_group_name

  # Regla de salida para permitir tráfico hacia On-Premises (VPN)
  security_rule {
    name                       = "AllowOutboundToOnPrem"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = var.premises.on_prem_cidr
  }

  tags = local.common_tags
}

# Asociación del NSG a la subred privada donde se desplegarán los nodos
resource "azurerm_subnet_network_security_group_association" "aks" {
  subnet_id                 = var.vnet.private_subnet_ids[0]
  network_security_group_id = azurerm_network_security_group.aks.id
}

# 2. Clúster de Kubernetes en Azure (AKS)
# Incorpora Control Plane, Node Groups, IAM Roles (Managed Identity), CNI Addon y OIDC Issuer
resource "azurerm_kubernetes_cluster" "main" {
  name                = "${var.environment}-aks-cluster"
  location            = var.location
  resource_group_name = var.vnet.resource_group_name
  dns_prefix          = "${var.environment}-aks"

  # Configuración del Node Group principal (Reemplaza a aws_eks_node_group)
  default_node_pool {
    name                 = "systempool"
    vm_size              = var.aks.node_instance_types[0] # Ej: "Standard_D2s_v5"
    vnet_subnet_id       = var.vnet.private_subnet_ids[0]
    auto_scaling_enabled = true
    node_count           = var.aks.desired_size
    min_count            = var.aks.min_size
    max_count            = var.aks.max_size
    os_disk_size_gb      = 30
    type                 = "VirtualMachineScaleSets"

    tags = local.common_tags
  }

  # Identidad Administrada (Reemplaza a los IAM Roles de EKS Control Plane y Nodes)
  identity {
    type = "SystemAssigned"
  }

  # Configuración de Red / CNI Addon (Reemplaza al AWS VPC CNI Add-on)
  network_profile {
    network_plugin    = "azure" # Azure CNI: asigna IPs de la VNet directamente a los pods
    load_balancer_sku = "standard"
    outbound_type     = "userDefinedRouting" # Si el tráfico sale vía NAT Gateway o Firewall
  }

  # Habilitar OIDC e Identity Workload (Reemplaza a aws_iam_openid_connect_provider / IRSA)
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Integración RBAC con Entra ID (Reemplaza a aws_eks_access_entry)
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
  }

  tags = local.common_tags

  depends_on = [
    azurerm_subnet_network_security_group_association.aks
  ]
}

# 3. Ejemplo de Credencial Federada para Workload Identity (Equivalente a una política IRSA en AWS)
# Permite vincular un ServiceAccount de Kubernetes con una identidad de Azure
resource "azurerm_user_assigned_identity" "app_identity" {
  name                = "${var.environment}-app-identity"
  location            = var.location
  resource_group_name = var.vnet.resource_group_name

  tags = local.common_tags
}

resource "azurerm_federated_identity_credential" "app_federated" {
  name                = "${var.environment}-app-federated-cred"
  resource_group_name = var.vnet.resource_group_name
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject             = "system:serviceaccount:default:my-app-sa" # namespace:serviceaccount
  parent_id           = azurerm_user_assigned_identity.app_identity.id
}