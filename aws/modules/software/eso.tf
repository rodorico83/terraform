## Configuration for External Secret Operator to allow Apps get secrets from AWS and store as kubernetes secrets

# 1.1. Política de Confianza (Trust Policy) para el ServiceAccount de ESO en EKS
data "aws_iam_policy_document" "eso_trust_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [  var.eks.oidc_provider_arn ]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.eks.oidc_issuer}:sub"
      # Apunta a la ServiceAccount central del operador de ESO
      values   = ["system:serviceaccount:external-secrets:eso-irsa-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.eks.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# 1.2. Rol de IAM Central de Plataforma para External Secrets
resource "aws_iam_role" "eso_platform_role" {
  name               = "eks-eso-platform-role"
  assume_role_policy = data.aws_iam_policy_document.eso_trust_policy.json
}

# 1.3. Política de lectura sobre Secrets Manager (Permite leer cualquier secreto que empiece por rds!db- o de aplicaciones)
resource "aws_iam_policy" "eso_secrets_policy" {
  name        = "EKSExternalSecretsGlobalReadPolicy"
  description = "Permite a ESO sincronizar secretos desde AWS Secrets Manager hacia Kubernetes"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        # Permite leer los secretos generados por RDS u organizados por rutas/entornos
        Resource = [
          "arn:aws:secretsmanager:*:*:secret:rds!db-*",
          "arn:aws:secretsmanager:*:*:secret:apps/*"
        ]
      }
    ]
  })
}

# 1.4 Attach previous policy to the role
resource "aws_iam_role_policy_attachment" "eso_attach" {
  role       = aws_iam_role.eso_platform_role.name
  policy_arn = aws_iam_policy.eso_secrets_policy.arn
}

# 2.1 creamos namespace
resource "kubernetes_namespace" "external_secrets" {
  metadata { name = "external-secrets" }
}

# 2.2 Define name for k8s service account
resource "kubernetes_service_account" "eso_sa" {
  metadata {
    name      = "eso-irsa-sa"
    namespace = "external-secrets"
    annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.eso_platform_role.arn }
  }
}



resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true

  # 🎯 OBLIGATORIO: Instala los CRDs (ClusterSecretStore, ExternalSecret, etc.)
  set {
    name  = "installCRDs"
    value = "true"
  }
  values = [
    yamlencode({
      # Controller: AWS Secret sync periodically, Secret creation in K8s,
      nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
      replicaCount = 1
      priorityClassName = "system-cluster-critical"
      resources = {
        requests = {
          cpu    = "50m"
          memory = "64Mi"
        }
        limits = {
          cpu    = "100m"
          memory = "128Mi"
        }
      }

      # Validating and Mutating Admission Webhook for ExternalSecret, SecretStore o ClusterSecretStore
      webhook = {
        nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
        replicaCount = 1
        priorityClassName = "system-cluster-critical"
        resources = {
          requests = {
            cpu    = "25m"
            memory = "64Mi"
          }
          limits = {
            cpu    = "100m"
            memory = "128Mi"
          }
        }
      }
      # Generation of certs for K8s API and Webhook pod communication
      certController = {
        replicaCount = 1
        nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
        priorityClassName = "system-cluster-critical"
        resources = {
          requests = {
            cpu    = "25m"
            memory = "64Mi"
          }
          limits = {
            cpu    = "100m"
            memory = "128Mi"
          }
        }
      }
    })
  ]
  depends_on = [kubernetes_service_account.eso_sa,kubectl_manifest.karpenter_node_pool_infra]
}

# ClusterSecretStore gestionado mediante kubectl_manifest
resource "kubectl_manifest" "cluster_secret_store" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ClusterSecretStore"
    metadata = { name = "aws-secretsmanager" }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.aws_region
          auth = {
            jwt = {
              serviceAccountRef = {
                name      = kubernetes_service_account.eso_sa.metadata[0].name
                namespace = kubernetes_service_account.eso_sa.metadata[0].namespace
              }
            }
          }
        }
      }
    }
  })

  validate_schema = false
  force_new       = true
  depends_on = [helm_release.external_secrets, kubernetes_service_account.eso_sa]
}