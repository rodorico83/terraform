output "eks" {
  description = "EKS Cluster metadata agrupado en un solo objeto."
  value = {
    id              = aws_eks_cluster.main.id
    name            = aws_eks_cluster.main.name
    endpoint        = aws_eks_cluster.main.endpoint
    cert            = aws_eks_cluster.main.certificate_authority[0].data
    node_role_arn   = aws_iam_role.eks_nodes.arn
    node_group_name = aws_eks_node_group.private_nodes.node_group_name
    node_group_arn  = aws_eks_node_group.private_nodes.arn
    cluster_sg      = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
    node_sg         = aws_security_group.eks_nodes.id
    oidc_arn        = aws_iam_openid_connect_provider.eks.arn
    oidc_url        = aws_iam_openid_connect_provider.eks.url
    pod_app_sg      = aws_security_group.pod_app_sg.id
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
    sg_group   = aws_security_group.db.id
    subnet_group_id = var.vpc.database_subnet_group_id
  }
}


/*output "github_actions_role_arn" {
  description = "IAM Role ARN created for GitHub Actions OIDC"
  value       = try(aws_iam_role.github_actions_tf[0].arn, null)
}*/

