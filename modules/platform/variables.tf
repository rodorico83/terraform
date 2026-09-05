variable "environment" {
  type        = string
  description = "Environment name (dev, staging, prod)"
}

variable "aws_region" {
  type        = string
  default     = "eu-west-1"
  description = "AWS Region"
}

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

variable "scaling_config" {
  type = object({
    desired_size = number
    min_size     = number
    max_size     = number
  })
  default = {
    desired_size = 2
    min_size     = 1
    max_size     = 4
  }
  description = "EKS node group scaling configuration"
}

variable "alb_security_group_id" {
  type        = string
  default     = null
  description = "Optional ALB security group allowed to reach application pods"
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

variable "enable_github_oidc" {
  type        = bool
  default     = false
  description = "Whether to create GitHub Actions OIDC provider and EKS Access Entry"
}

variable "github_repository" {
  type        = string
  default     = "*"
  description = "GitHub repository allowed to assume the role (e.g. my-org/my-repo)"
}
