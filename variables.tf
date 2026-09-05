

variable "aws_region" {
  type    = string
  default = "eu-west-1"
}
variable "environment" {
  type    = string
  default = "dev"
}

# Red de AWS (VPC)
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

# Red de su Centro de Datos Local (On-Premises)
variable "on_prem_cidr" {
  type        = string
  default     = "192.168.0.0/16"
  description = "Rango de IPs de la red local / Servidores On-Premises"
}

# IP Pública de su router/firewall local en sus oficinas
variable "on_prem_public_ip" {
  type    = string
  default = "203.0.113.50" # Cambiar por su IP pública real estática
}

variable "on_prem_kubernetes_token" {
  type        = string
  description = "Token de autenticación de la cuenta de servicio de su clúster local"
  sensitive   = true # <--- OBLIGATORIO: Terraform enmascarará el token en la CLI (1 opcion como env var TF_VAR (mas segura), 2 Opcion declarar en .tfvars file)
}


variable "db_config" {
  type = object({
    engine         = string
    engine_version = string
    instance_class = string
    port           = number
    database_name  = string
    admin_username = string
  })
  default = {
    engine         = "postgres"
    engine_version = "15.4"
    instance_class = "db.t4g.micro"
    port           = 5432
    database_name  = "example"
    admin_username = "db_cluster_admin" # Evite usar nombres genéricos como "admin" o "postgres"
  }
  description = "Configuracion general no sensible para el motor de Base de Datos"
}