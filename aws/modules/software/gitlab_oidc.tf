# 1. Proveedor OIDC para GitLab
resource "aws_iam_openid_connect_provider" "gitlab" {
  count          = var.gitlab.enable_gitlab_oidc ? 1 : 0
  url            = "https://gitlab.com"
  client_id_list = ["https://gitlab.com"]

  # En instancias SaaS de GitLab no siempre es estrictamente necesario especificar la huella,
  # pero si tu proveedor lo exige, esta es la raíz del certificado de GitLab.
  thumbprint_list = ["b3dd7606d2b5a8b4a13771dbecc9ee1cecaffb0a"]
  tags = local.common_tags
}

# 2. Rol IAM para los pipelines de GitLab CI
resource "aws_iam_role" "gitlab_ci_tf" {
  count = var.gitlab.enable_gitlab_oidc ? 1 : 0
  name  = "gitlab-ci-eks-executor"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.gitlab[0].arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = { "gitlab.com:aud" : "https://gitlab.com" }
          # Formato de restricción para proyectos y ramas en GitLab:
          StringLike = { "gitlab.com:sub" : "project_path:${var.gitlab.gitlab_project_path}:ref_type:branch:ref:${var.gitlab.target_branch}" }
        }
      }
    ]
  })
  permissions_boundary = aws_iam_policy.pipeline_boundary[0].arn
  tags = local.common_tags
}

# 3. Permisos en AWS para la ejecución del pipeline
# Opcion 3.1: full access not standard
resource "aws_iam_role_policy_attachment" "gitlab_ci_admin" {
  count      = var.gitlab.enable_gitlab_oidc ? 1 : 0
  role       = aws_iam_role.gitlab_ci_tf[0].name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# Opcion 3.2: Permission boundaries
resource "aws_iam_policy" "pipeline_boundary" {
  name        = "PipelineSecurityBoundary"
  description = "Deniega acciones destructivas críticas en producción"
  count      = var.gitlab.enable_gitlab_oidc ? 1 : 0

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowEverythingElse"
        Effect   = "Allow"
        Action   = "*"
        Resource = "*"
      },
      {
        Sid    = "DenyCriticalDeletions"
        Effect = "Deny"
        Action = [
          "rds:DeleteDBInstance",
          "rds:DeleteDBCluster",
          "s3:DeleteBucket",
          "kms:ScheduleKeyDeletion"
        ]
        Resource = "*"
      }
    ]
  })
}

# 4. Mapeo en el plano de control de EKS (Access Entry)
resource "aws_eks_access_entry" "gitlab_pipeline_access" {
  count         = var.gitlab.enable_gitlab_oidc ? 1 : 0
  cluster_name  = var.eks.cluster_name
  principal_arn = aws_iam_role.gitlab_ci_tf[0].arn
  type          = "STANDARD"
}

# 5. Autorización como ClusterAdmin dentro de Kubernetes
resource "aws_eks_access_policy_association" "gitlab_pipeline_admin" {
  count         = var.gitlab.enable_gitlab_oidc ? 1 : 0
  cluster_name  = var.eks.cluster_name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = aws_eks_access_entry.gitlab_pipeline_access[0].principal_arn

  access_scope {
    type = "cluster"
  }
}