output "eks" {
  description = "EKS Cluster metadata expuesto al estado remoto."
  value       = module.platform.eks
}

output "db" {
  description = "Database metadata expuesto al estado remoto."
  value       = module.platform.db
}

output "pod_app_sg_id" {
  description = "Security Group ID para los Pods con ENI dedicada."
  value       = module.platform.pod_app_sg_id
}
