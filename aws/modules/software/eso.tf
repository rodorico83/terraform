## Configuration for External Secret Operator to allow Apps get secrets from AWS and store as kubernetes secrets

# 1.1. Política de Confianza (Trust Policy) para el ServiceAccount de ESO en EKS
data "aws_iam_policy_document" "eso_trust_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [  var.eks.oidc_provider_arn ]
      #identifiers = [  module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.eks.oidc_provider_url, "https://", "")}:sub"
      # Apunta a la ServiceAccount central del operador de ESO
      values   = ["system:serviceaccount:external-secrets:eso-irsa-sa"]
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
  metadata {
    name = "external-secrets"
  }
}

# 2.2 Define name for k8s service account
resource "kubernetes_service_account" "eso_sa" {
  metadata {
    name      = "eso-irsa-sa"
    namespace = "external-secrets"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.eso_platform_role.arn
    }
  }
}


/*resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true

  set {
    name  = "installCRDs"
    value = "true"
  }

  # Inyecta directamente la configuración del ClusterSecretStore en la instalación del chart
  # Inyecta el ClusterSecretStore mediante extraObjects para despliegue atómico
  values = [
    yamlencode({
      extraObjects = [
        {
          apiVersion = "external-secrets.io/v1beta1"
          kind       = "ClusterSecretStore"
          metadata = {
            name = "aws-secretsmanager"
          }
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
        }
      ]
    })
  ]
  values = [
    yamlencode({
      processClusterStores = true
      clusterSecretStores = [
        {
          name = "aws-secretsmanager"
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
        }
      ]
    })
  ]

  depends_on = [
    kubernetes_service_account.eso_sa
  ]
}*/

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
      nodeSelector = { "eks.amazonaws.com/nodegroup" = "private-workers" }
      webhook = { nodeSelector = { "eks.amazonaws.com/nodegroup" = "private-workers" } }
      certController = { nodeSelector = { "eks.amazonaws.com/nodegroup" = "private-workers" } }
    })
  ]
  depends_on = [
    kubernetes_service_account.eso_sa
  ]
}

# 6. ClusterSecretStore desplegado vía Helm para evitar errores de API client en Terraform
/*resource "helm_release" "cluster_secret_store" {
  name       = "eso-cluster-secret-store"
  repository = "https://bedag.github.io/helm-charts/"
  chart      = "raw"
  namespace  = "external-secrets"

  values = [
    yamlencode({
      resources = [
        {
          apiVersion = "external-secrets.io/v1beta1"
          kind       = "ClusterSecretStore"
          metadata = {
            name = "aws-secretsmanager"
          }
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
        }
      ]
    })
  ]

  depends_on = [
    helm_release.external_secrets,
    kubernetes_service_account.eso_sa
  ]
}*/

# 6. ClusterSecretStore gestionado mediante kubectl_manifest
/*resource "null_resource" "apply_cluster_secret_store" {
  provisioner "local-exec" {
    command = <<EOT
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secretsmanager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ${var.aws_region}
      auth:
        jwt:
          serviceAccountRef:
            name: ${kubernetes_service_account.eso_sa.metadata[0].name}
            namespace: ${kubernetes_service_account.eso_sa.metadata[0].namespace}
EOF
EOT
  }

  depends_on = [
    helm_release.external_secrets,
    kubernetes_service_account.eso_sa
  ]
}*/

resource "kubectl_manifest" "cluster_secret_store" {
  yaml_body = <<YAML
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-secretsmanager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ${var.aws_region}
      auth:
        jwt:
          serviceAccountRef:
            name: ${kubernetes_service_account.eso_sa.metadata[0].name}
            namespace: ${kubernetes_service_account.eso_sa.metadata[0].namespace}
YAML

  validate_schema   = false
  force_new         = true

  depends_on = [
    helm_release.external_secrets,
    kubernetes_service_account.eso_sa
  ]
}

/*resource "kubernetes_manifest" "cluster_secret_store" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata = {
      name = "aws-secretsmanager"
    }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.aws_region # Reemplaza por tu región de AWS
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
  }
  depends_on = [ helm_release.external_secrets, kubernetes_service_account.eso_sa ]
}*/