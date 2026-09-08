output "eks" {
  description = "EKS Cluster metadata expuesto al estado remoto."
  value       = module.platform.eks
}

output "db" {
  description = "Database metadata expuesto al estado remoto."
  value       = module.platform.db
}


output "storage" {
  description = "Storage metadata expuesto al estado remoto."
  value       = module.platform.storage
}