/*
# 1. Definir la política de confianza que permite a Wiz asumir el rol
data "aws_iam_policy_document" "wiz_assume_role" {
  count      = var.enable_wiz ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::197346215321:root"] # ID de cuenta AWS global de Wiz (ejemplo)
    }
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = ["tu-external-id-de-wiz"]
    }
  }
}

# 2. Crear el rol de IAM para Wiz
resource "aws_iam_role" "wiz_role" {
  count      = var.enable_wiz ? 1 : 0
  name               = "WizAccessRole"
  assume_role_policy = data.aws_iam_policy_document.wiz_assume_role[0].json
}

# 3. Adjuntar las políticas que Wiz solicita (solo lectura y auditoría de seguridad)
resource "aws_iam_role_policy_attachment" "wiz_security_audit" {
  count      = var.enable_wiz ? 1 : 0
  role       = aws_iam_role.wiz_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"
}

# (Opcional: Se adjuntan políticas adicionales de Wiz para escaneo de volúmenes EBS de EKS)

# 5. Dar de alta el conector de AWS vinculando el Rol creado en el Paso 1
resource "wiz_aws_connector" "aws_eks_environment" {
  count      = var.enable_wiz ? 1 : 0
  name = "Production-EKS-Environment"
  auth_params {
    customer_role_arn = aws_iam_role.wiz_role[0].arn
  }
  extra_config {
    opted_in_regions = ["eu-south-2"]
  }
}


# 6. Desplegar el Wiz Sensor como DaemonSet en On-Premises (vía Helm)
resource "helm_release" "wiz_sensor" {
  count      = var.enable_wiz ? 1 : 0
  name             = "wiz-sensor"
  repository       = "https://charts.wiz.io" # Repositorio oficial de Wiz
  chart            = "wiz-sensor"
  namespace        = "wiz"
  create_namespace = true

  provider = helm.onprem

  set {
    name  = "wizApiToken"
    value = var.wiz.sensor_token # Token generado previamente en Wiz
  }

  set {
    name  = "clusterName"
    value = "on-premises-core-cluster"
  }

  # Si tu red local está muy aislada, aquí mapeas la conexión hacia el "Wiz Broker"
  # set {
  #   name  = "broker.endpoint"
  #   value = "http://local.lan"
  # }
}

*/