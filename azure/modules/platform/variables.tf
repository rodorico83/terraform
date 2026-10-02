variable "environment" {
  type        = string
  description = "Environment name (dev, staging, prod)"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment debe ser dev, staging o prod."
  }
}

variable "location" {
  type        = string
  default     = "spaincentral"
  description = "Región de Azure"
}

variable "vnet" {
  type = object({
    id                       = string
    name                     = string
    resource_group_name      = string
    private_subnet_ids       = list(string)
    database_subnet_ids      = list(string)
    database_subnet_group_id = string
    enable_vpn               = bool
  })
  description = "Objeto con los datos de red provenientes del módulo VNet"
}

variable "premises" {
  type = object({
    on_prem_cidr   = string
    on_prem_domain = string
    on_prem_dns_ip = string
  })
  default = {
    on_prem_cidr   = "192.168.0.0/16"
    on_prem_domain = ""
    on_prem_dns_ip = ""
  }
  description = "Configuración de la red On-Premises"
}

variable "aks" {
  type = object({
    node_instance_types = list(string)
    desired_size        = number
    min_size            = number
    max_size            = number
  })
  default = {
    node_instance_types = ["Standard_D2s_v5"]
    desired_size        = 2
    min_size            = 1
    max_size            = 4
  }
  description = "Configuración de escalado del cluster AKS"
}

variable "db_config" {
  type = object({
    engine         = string
    engine_version = string
    instance_class = string
    port           = number
    database_name  = string
    admin_username = string
    enabled        = string
  })
  default = {
    engine         = "postgres"
    engine_version = "15"
    instance_class = "GP_Standard_D2s_v3"
    port           = 5432
    database_name  = "example"
    admin_username = "db_cluster_admin"
    enabled        = "true"
  }
  description = "Configuración de PostgreSQL Flexible Server"
}