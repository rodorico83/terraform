variable "environment" {
  type        = string
  description = "Environment name (dev, staging, prod)"

  # db.tf compara contra "prod" para activar multi_az, deletion_protection y
  # retencion de backups. Un valor como "production" los desactivaria en
  # silencio, asi que el conjunto de valores es cerrado.
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment debe ser dev, staging o prod."
  }
}

variable "aws_region" {
  type        = string
  default     = "eu-south-2"
  description = "AWS Region"
}

variable "vpc" {
  type = object({
    vpc_id                    = string
    private_subnet_ids        = list(string)
    database_subnet_group_id  = string
    enable_vpn                = bool
  })
  description = "VPC configuration"
}


variable "premises" {
  type = object({
    on_prem_cidr    = string
    on_prem_domain  = string
    on_prem_dns_ip  = string
  })
  default = {
    on_prem_cidr    = "192.168.0.0/16"
    on_prem_domain  = ""
    on_prem_dns_ip  = ""
  }
  description = "OnPremises network configuration"

  /*validation {
    condition     = length(trimspace(var.premises.on_prem_domain)) > 0
    error_message = "on_prem_domain no puede estar vacio: se usa como nombre de zona en el Corefile de CoreDNS."
  }

  validation {
    condition     = can(cidrnetmask("${var.premises.on_prem_dns_ip}/32"))
    error_message = "on_prem_dns_ip debe ser una direccion IPv4 valida."
  }*/

}

variable "eks" {
  type = object({
    node_instance_types = list(string)
    node_capacity_type = string
    desired_size = number
    min_size     = number
    max_size     = number
    enable_pod_eni      = bool
  })
  default = {
    node_instance_types = ["t3.medium"]
    node_capacity_type = "ON_DEMAND"
    desired_size = 2
    min_size     = 1
    max_size     = 4
    enable_pod_eni      = false
  }
  description = "EKS node group scaling configuration"
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
    engine_version = "18.6"
    instance_class = "db.t4g.micro"
    port           = 5432
    database_name  = "example"
    admin_username = "db_cluster_admin"
    enabled        = "true"
  }
  description = "Database configuration settings"
}

variable "devops_role_arn" {
  type        = string
  default     = null
  description = "IAM Role ARN for DevOps team EKS Access Entry"
}

variable "app_container_port" {
  type        = number
  default     = 8080
  description = "Container port the application pods listen on. ingress-nginx routes to the pod IP on this port, not to the Service port."
}

