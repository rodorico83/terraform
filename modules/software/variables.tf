variable "environment" {
  type        = string
  description = "Environment name"
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
