variable "environment" {
  type        = string
  description = "Environment name (dev, staging, prod)"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment debe ser dev, staging o prod."
  }
}

variable "enable_argocd" {
  type        = bool
  default     = true
  description = "Whether to install ArgoCD"
}

variable "enable_reloader" {
  type        = bool
  default     = true
  description = "Whether to install Stakater Reloader"
}

variable "enable_ingress_nginx" {
  type        = bool
  default     = true
  description = "Whether to install NGINX Ingress Controller"
}

variable "enable_cert_manager" {
  type        = bool
  default     = true
  description = "Whether to install Cert-Manager"
}

variable "vpc" {
  type = object({
    vpc_id                    = string
    private_subnet_ids        = string
    database_subnet_group_id  = string
  })
  default = {
    vpc_id                    = ""
    private_subnet_ids        = ""
    database_subnet_group_id  = ""
  }
  description = "VPC configuration"
}

/*
variable "vpc_id" {
  type        = string
  description = "VPC ID where the platform resources are deployed"
}*/

variable "db" {
  type = object({
    db_port           = number
    sg_group_db_id    = string
    database_subnet_group_id  = string
  })
  description = "VPC configuration"
}
/*
variable "db_port" {
  type        = number
  description = "Port the RDS instance listens on"
}

variable "sg_group_db_id" {
  type        = string
  description = "Security Group ID of the RDS instance"
}*/

variable "premises" {
  type = object({
    cluster_prod_endpoint = string
    cluster_dev_endpoint = string
    cluster_prod_ca = string
    cluster_dev_ca = string
    on_prem_cidr = string
  })
  description = "On-premises details"
}
/*
variable "on_prem_cidr" {
  type        = string
  description = "On-premises network CIDR"
}

variable "on_prem_cluster_prod_endpoint" {
  type        = string
  description = "CLuster endpoint of the on-premises Prod cluster"
}

variable "on_prem_cluster_dev_endpoint" {
  type        = string
  description = "CLuster endpoint of the on-premises Dev cluster"
}*/

variable "eks" {
  type = object({
    cluster_name = string
    cluster_endpoint = string
    cluster_sg = string
    oidc_provider_arn = string
    oidc_provider_url = string
    node_role_arn = string
    pod_app_sg = string
    ca_certificate = string
  })
  description = "EKS node group scaling configuration"
}


/*
variable "node_security_group_id" {
  type        = string
  description = "EKS cluster security group; source of ingress-nginx traffic to app pods"
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name, required by the AWS Load Balancer Controller"
}

variable "cluster_endpoint" {
  type        = string
  description = "EKS cluster endpoint, required by the AWS Load Balancer Controller"
}

variable "oidc_provider_arn" {
  type        = string
  description = "IAM OIDC provider ARN of the EKS cluster, used for IRSA"
}

variable "oidc_provider_url" {
  type        = string
  description = "IAM OIDC provider URL of the EKS cluster, used for IRSA"
}

variable "node_role_arn" {
  type        = string
  description = "Role Used for the EKS Worker nodes"
}*/



variable "app_pod_selector_labels" {
  type        = map(string)
  default     = { role = "backend-app" }
  description = "Pod labels that receive the dedicated pod_app_sg branch ENI"
}

variable "app_namespace" {
  type        = string
  default     = "default"
  description = "Namespace the SecurityGroupPolicy applies to"
}

variable "nlb_scheme" {
  type        = string
  default     = "internet-facing"
  description = "Scheme for the NLB fronting ingress-nginx (internet-facing or internal)"

  validation {
    condition     = contains(["internet-facing", "internal"], var.nlb_scheme)
    error_message = "nlb_scheme must be either internet-facing or internal."
  }
}

variable "storage" {
  type = object({
    ebs_csi_driver_rol_name = string
  })
}


variable "github" {
  type = object({
    enable_github_oidc = bool
    github_repository = string
  })
  default = {
    enable_github_oidc = false
    github_repository = ""
  }
  description = "EKS node group scaling configuration"
}

/*
variable "enable_github_oidc" {
  type    = bool
  default = true
}

variable "github_repository" {
  type    = string
  default = "my-enterprise-org/my-infra-repo"
}*/




