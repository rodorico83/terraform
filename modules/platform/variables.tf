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
  default     = "eu-west-1"
  description = "AWS Region"
}

variable "vpc" {
  type = object({
    vpc_id                    = string
    private_subnet_ids        = string
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

  validation {
    condition     = length(trimspace(var.premises.on_prem_domain)) > 0
    error_message = "on_prem_domain no puede estar vacio: se usa como nombre de zona en el Corefile de CoreDNS."
  }

  validation {
    condition     = can(cidrnetmask("${var.premises.on_prem_dns_ip}/32"))
    error_message = "on_prem_dns_ip debe ser una direccion IPv4 valida."
  }

}

/*
variable "vpc_id" {
  type        = string
  description = "VPC ID where the platform resources are deployed"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Subnet IDs for EKS control plane and worker nodes"
}

variable "database_subnet_group_id" {
  type        = string
  description = "Database Subnet Group ID"
}

variable "on_prem_cidr" {
  type        = string
  default     = "192.168.0.0/16"
  description = "On-premises network CIDR"
}

variable "on_prem_domain" {
  type        = string
  description = "On-premises network Domain"

  validation {
    condition     = length(trimspace(var.on_prem_domain)) > 0
    error_message = "on_prem_domain no puede estar vacio: se usa como nombre de zona en el Corefile de CoreDNS."
  }
}

variable "on_prem_dns_ip" {
  type        = string
  description = "On-premises network DNS Server"

  # Un valor vacio genera `forward .` sin upstream, que es un Corefile invalido:
  # CoreDNS entra en CrashLoopBackOff y se cae el DNS de todo el cluster.
  validation {
    condition     = can(cidrnetmask("${var.on_prem_dns_ip}/32"))
    error_message = "on_prem_dns_ip debe ser una direccion IPv4 valida."
  }
}

variable "node_instance_types" {
  type        = list(string)
  default     = ["t3.medium"]
  description = "Instance types for EKS worker nodes"
}

variable "node_capacity_type" {
  type        = string
  default     = "ON_DEMAND"
  description = "Capacity type for worker nodes (ON_DEMAND or SPOT)"
}
*/

variable "eks" {
  type = object({
    node_instance_types = list(string)
    node_capacity_type = string
    desired_size = number
    min_size     = number
    max_size     = number
  })
  default = {
    node_instance_types = ["t3.medium"]
    node_capacity_type = "ON_DEMAND"
    desired_size = 2
    min_size     = 1
    max_size     = 4
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
  })
  default = {
    engine         = "postgres"
    engine_version = "15.4"
    instance_class = "db.t4g.micro"
    port           = 5432
    database_name  = "example"
    admin_username = "db_cluster_admin"
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

