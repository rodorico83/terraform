# inyecte el controlador nativo de almacenamiento dentro de los nodos del clúster
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = "v1.35.0-eksbuild.1" # Versión compatible certificada para producción en 2026
  service_account_role_arn = aws_iam_role.ebs_csi_driver.arn

  tags = local.common_tags

  # OBLIGATORIO: El Add-on necesita que los nodos Spot ya existan y estén Ready
  depends_on = [aws_eks_node_group.private_nodes, aws_iam_role_policy_attachment.ebs_csi_policy]
}

# creamos el recurso StorageClass de Kubernetes usando Terraform y lo marcamos como la clase por defecto del sistema
resource "kubernetes_storage_class_v1" "gp3_default" {
  provider = kubernetes.aws_eks

  metadata {
    name = "gp3"
    annotations = {
      # ─── EL TRUCO DE COMPATIBILIDAD UNIVERSAL ───
      # Le dice a Kubernetes que si cualquier aplicación pide disco sin especificar el nombre,
      # use esta clase gp3 automáticamente, ahorrando costes frente a gp2.
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  # Indicamos que el traductor oficial es el driver que acabamos de instalar
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer" # Optimiza costes: crea el disco solo cuando el Pod se va a encender
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  # Forzamos a esperar a que el Add-on de AWS esté 100% activo en la red
  depends_on = [aws_eks_addon.ebs_csi]
}


# Rol de confianza para el ServiceAccount del Driver de Almacenamiento
resource "aws_iam_role" "ebs_csi_driver" {
  name        = "${var.environment}-ebs-csi-driver-role"
  description = "Permisos IAM para que el driver de Kubernetes gestione discos duros gp3 de AWS"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer_host}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${local.oidc_issuer_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}