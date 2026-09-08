# ==============================================================================
# 1. CAPA DE SEGURIDAD (PERMISOS IAM PARA QUE GRAFANA LEA AWS CLOUDWATCH)
# ==============================================================================
resource "aws_iam_role" "grafana_aws_reader" {
  count       = var.environment == "prod" ? 1 : 0
  name        = "grafana-iam-role"
  description = "Rol IAM para que Grafana lea metricas de hardware de RDS y VPN en AWS"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.eks.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          # OJO: la condicion IRSA se construye sobre el emisor OIDC del cluster,
          # NO sobre el endpoint del API server: son hostnames distintos.
          # Restringimos el rol estrictamente a la ServiceAccount de Grafana.
          "${local.oidc_issuer_host}:sub" = "system:serviceaccount:monitoring:kube-prometheus-stack-grafana"
          "${local.oidc_issuer_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "grafana_cloudwatch_readonly" {
  count      = var.environment == "prod" ? 1 : 0
  role       = aws_iam_role.grafana_aws_reader.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

# ==============================================================================
# 2. CREDENCIAL DE ADMINISTRACION DE GRAFANA
# ==============================================================================
# Generada, no escrita en el repositorio. Sigue quedando en el state de
# Terraform, asi que el state debe estar cifrado (ya lo esta) y con acceso
# restringido.
resource "random_password" "grafana_admin" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "grafana_admin" {
  count       = var.environment == "prod" ? 1 : 0
  name        = "${var.environment}/grafana/admin-password"
  description = "Grafana admin password for the kube-prometheus-stack release"
  tags        = local.common_tags
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  count            = var.environment == "prod" ? 1 : 0
  secret_id     = aws_secretsmanager_secret.grafana_admin.id
  secret_string = random_password.grafana_admin.result
}

# ==============================================================================
# 3. INSTALACION AUTOMATIZADA DE LA SUITE DE OBSERVABILIDAD VIA HELM
# ==============================================================================

# Adjuntar la política oficial administrada por AWS para controladores EBS
resource "aws_iam_role_policy_attachment" "ebs_csi_policy" {
  count      = var.environment == "prod" ? 1 : 0
  role       = var.storage.ebs_csi_driver_rol_name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}


resource "helm_release" "kube_prometheus_stack" {
  count            = var.environment == "prod" ? 1 : 0
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "56.6.2"
  namespace        = "monitoring"
  create_namespace = true

  # --- INYECCION DE VALUES AVANZADOS MEDIANTE JSONENCODE ---
  values = [
    jsonencode({
      # A) Configuracion Avanzada de Grafana
      grafana = {
        enabled = true
        serviceAccount = {
          create = true
          annotations = {
            # Clave de anotacion IRSA exacta que exige el webhook de EKS.
            "eks.amazonaws.com/role-arn" = aws_iam_role.grafana_aws_reader.arn
          }
        }
      }

      # B) Configuracion del Almacenamiento Persistente de Prometheus
      # Evita que las metricas se borren si las instancias EC2 Spot se reinician.
      # Requiere el addon aws-ebs-csi-driver y una StorageClass gp3 (ver README).
      prometheus = {
        prometheusSpec = {
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                accessModes      = ["ReadWriteOnce"]
                storageClassName = "gp3"
                resources = {
                  requests = {
                    storage = "20Gi"
                  }
                }
              }
            }
          }
        }
      }

      # C) Componentes Core de Monitoreo del Cluster
      kubeStateMetrics = { enabled = true }
      nodeExporter     = { enabled = true }
    })
  ]

  # La password no va en `values` para que no acabe en el diff en claro.
  set_sensitive {
    name  = "grafana.adminPassword"
    value = random_password.grafana_admin.result
  }

  # OBLIGATORIO: esperar a que EKS y sus nodos esten Ready antes de inyectar Helm
  depends_on = [
    aws_iam_role_policy_attachment.grafana_cloudwatch_readonly
  ]
}
