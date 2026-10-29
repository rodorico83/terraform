# Bucket S3 para trazas de Tempo
resource "aws_s3_bucket" "tempo_storage" {
  count         = var.enable_monitoring ? 1 : 0
  bucket        = "rj-engineering-${var.environment}-tempo-${var.eks.cluster_name}"
  force_destroy = false
}

# Rol IAM con IRSA para ServiceAccount de Tempo
resource "aws_iam_role" "tempo_s3" {
  count = var.enable_monitoring ? 1 : 0
  name  = "tempo-s3-${var.environment}-${var.eks.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.eks.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.eks.oidc_issuer}:sub" = "system:serviceaccount:monitoring:tempo"
          "${var.eks.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "tempo_s3" {
  count = var.enable_monitoring ? 1 : 0
  role  = aws_iam_role.tempo_s3[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:ListBucket",
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject"
      ]
      Resource = [aws_s3_bucket.tempo_storage[0].arn, "${aws_s3_bucket.tempo_storage[0].arn}/*"]
    }]
  })
}

# Helm Release de Grafana Tempo
resource "helm_release" "tempo" {
  count            = var.enable_monitoring ? 1 : 0
  name             = "tempo"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "tempo"
  version          = "1.10.3"
  namespace        = "monitoring"
  create_namespace = false

  values = [
    jsonencode({
      serviceAccount = {
        create = true
        name   = "tempo"
        annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.tempo_s3[0].arn }
      }

      tempo = {
        resources = {
          requests = {
            cpu    = "50m"
            memory = "256Mi"
          }
          limits = {
            cpu    = "100m"
            memory = "512Mi"
          }
        }
        repository = "grafana/tempo"
        storage = {
          trace = {
            backend = "s3"
            s3 = {
              bucket = aws_s3_bucket.tempo_storage[0].bucket
              region = var.aws_region
              endpoint = "s3.${var.aws_region}.amazonaws.com"
            }
          }
        }
        receivers = {
          otlp = {
            protocols = {
              grpc = { endpoint = "0.0.0.0:4317" }
              http = { endpoint = "0.0.0.0:4318" }
            }
          }
        }
      }

      persistence = {
        enabled      = true
        storageClass = "gp3"
        size         = "10Gi"
      }

      nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }


    })
  ]
  depends_on = [aws_iam_role.tempo_s3,helm_release.kube_prometheus_stack,kubectl_manifest.karpenter_node_pool_infra]
}