# 1. Establish Secure OIDC Trust with GitHub Actions
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.github.enable_github_oidc ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a2a858174f5219f120e6e0b7b036c0c2f0f1"]
  tags = local.common_tags
}

# 2. Create the IAM Role for GitHub Actions pipeline
resource "aws_iam_role" "github_actions_tf" {
  count = var.github.enable_github_oidc ? 1 : 0
  name  = "github-actions-eks-executor"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.github[0].arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = { "token.actions.githubusercontent.com:aud" : "sts.amazonaws.com" }
          StringLike = { "token.actions.githubusercontent.com:sub" : "repo:${var.github.github_repository}:ref:refs/heads/master" }
        }
      }
    ]
  })

  tags = local.common_tags
}

# 3. Standard EKS inspection / pipeline permissions
resource "aws_iam_role_policy_attachment" "github_actions_admin" {
  count      = var.github.enable_github_oidc ? 1 : 0
  role       = aws_iam_role.github_actions_tf[0].name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}


# 4. Map the Pipeline Role to the EKS Cluster (Access Entry)
resource "aws_eks_access_entry" "pipeline_access" {
  count         = var.github.enable_github_oidc ? 1 : 0
  cluster_name  = var.eks.cluster_name
  principal_arn = aws_iam_role.github_actions_tf[0].arn
  type          = "STANDARD"
}

# 5. Authorize the Pipeline Role with Admin access inside Kubernetes
resource "aws_eks_access_policy_association" "pipeline_admin" {
  count         = var.github.enable_github_oidc ? 1 : 0
  cluster_name  = var.eks.cluster_name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = aws_eks_access_entry.pipeline_access[0].principal_arn
  access_scope { type = "cluster" }
}
