output "eks" {
  description = "EKS Cluster metadata agrupado en un solo objeto."
  value = {
    id              = aws_eks_cluster.main.id
    name            = aws_eks_cluster.main.name
    endpoint        = aws_eks_cluster.main.endpoint
    cert            = aws_eks_cluster.main.certificate_authority[0].data
    node_group_name = aws_eks_node_group.private_nodes.node_group_name
  }
}

output "db" {
  description = "Database metadata agrupado en un solo objeto."
  value = {
    id         = aws_db_instance.postgres.id
    name       = aws_db_instance.postgres.db_name
    port       = aws_db_instance.postgres.port
    endpoint   = aws_db_instance.postgres.address
    secret_arn = try(aws_db_instance.postgres.master_user_secret[0].secret_arn, null)
  }
}

output "pod_app_sg_id" {
  description = "Security Group ID para los Pods con ENI dedicada."
  value       = aws_security_group.pod_app_sg.id
}

output "github_actions_role_arn" {
  description = "IAM Role ARN created for GitHub Actions OIDC"
  value       = try(aws_iam_role.github_actions_tf[0].arn, null)
}
