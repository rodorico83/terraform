variable "environment" {
  type        = string
  description = "Environment name (dev, staging, prod)"

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

variable "enable_istio" {
  type        = bool
  default     = false
  description = "Whether to enable Istio/Envoy Service mesh"
}

variable "enable_monitoring" {
  type        = bool
  default     = false
  description = "Whether to enable Prometheus/grafana stack"
}

variable "enable_finops" {
  type        = bool
  default     = true
  description = "Whether to enable Prometheus/grafana stack"
}

variable "enable_eck" {
  type        = bool
  default     = false
  description = "Whether to enable ECK stack (Elastic cloud on kubernetes) FLuent-bit, Logstash, Elastic and Kibana"
}

variable "enable_wiz" {
  type        = bool
  default     = false
  description = "Whether to enable Wiz"
}

variable "enable_pod_eni" {
  type        = bool
  default     = false
  description = "Whether to enable POD Network interface (ENI)"
}
variable "grafana_read_token" {
  type        = string
  default     = "glsa_eODcSCxIbG0ZDjzX45lLbhHH4qYUuCET_de194222"
  sensitive = true
  description = "Grafana read token"
}
variable "wiz" {
  type = object({
    enable         = bool
    client_id      = string
    client_secret  = string
    sensor_token   = string
  })
  default = {
    enable         = false
    client_id      = null
    client_secret  = null
    sensor_token   = null
  }
  description = "Wiz configuration"
}

variable "vpc" {
  type = object({
    vpc_id                    = string
    private_subnet_ids        = list(string)
    database_subnet_group_id  = string
  })
  default = {
    vpc_id                    = ""
    private_subnet_ids        = []
    database_subnet_group_id  = ""
  }
  description = "VPC configuration"
}


variable "db" {
  type = object({
    db_port           = number
    sg_group_db_id    = string
    database_subnet_group_id  = string
  })
  description = "VPC configuration"
}

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

variable "eks" {
  type = object({
    cluster_name = string
    cluster_endpoint = string
    cluster_sg = string
    oidc_provider_arn = string
    oidc_provider_url = string
    node_role_arn = string
    pod_app_sg = string
    node_sg = string
    ca_certificate = string
  })
  description = "EKS node group scaling configuration"
}

variable "app_pod_selector_labels" {
  type        = map(string)
  default     = { role = "backend-app" }
  description = "Pod labels that receive the dedicated pod_app_sg branch ENI"
}

variable "app_namespace" {
  type        = string
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

variable "github" {
  type = object({
    enable_github_oidc = bool
    github_repository = string
    read_token = string
  })
  default = {
    enable_github_oidc = false
    github_repository = null
    read_token = null
  }
  description = "EKS node group scaling configuration"
}





