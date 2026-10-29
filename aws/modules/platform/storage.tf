#### EBS ###

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
          "${local.oidc_issuer}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

# Adjuntar la política oficial administrada por AWS para controladores EBS
resource "aws_iam_role_policy_attachment" "ebs_csi_policy" {
  role       = aws_iam_role.ebs_csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}



# Instancias t3.medium / t4g.medium (2 vCPUs, 4 GiB RAM)
# Rendimiento de Red: Hasta 5 Gbps.
# IOPS de línea base (Baseline): ~2,000 IOPS
# Throughput de línea base: ~43.38 MB/s
# IOPS máximos (Pico): Hasta 11,800 IOPS
# Throughput máximo (Pico): ~260.6 MB/s

# Instancias t3.large / t4g.large (2 vCPUs, 8 GiB RAM)
# Rendimiento de Red: Hasta 5 Gbps.
# IOPS de línea base (Baseline): ~4,000 IOPS
# Throughput de línea base: ~86.88 MB/s
# IOPS máximos (Pico): Hasta 15,700 IOPS (en t4g) / ~11,800 IOPS (en t3)
# Throughput máximo (Pico): ~347.5 MB/s (en t4g) / ~260.6 MB/s (en t3)

# Instancias r6g.medium (1 vCPU, 8 GiB RAM)
# Rendimiento de Red: Hasta 10 Gbps.
# Throughput máximo hacia EBS (Pico): ~593.75 MB/s (mucho mayor que los 260 MB/s de una t3).
# IOPS máximo hacia EBS: Hasta 20,000 IOPS.
# Rendimiento de línea base (Sostenido): ~78.75 MB/s y ~3,600 IOPS.

# Instancias r6g.large (2 vCPUs, 16 GiB RAM)
# Rendimiento de Red: Hasta 10 Gbps.
# Throughput máximo hacia EBS (Pico): ~593.75 MB/s.
# IOPS máximo hacia EBS: Hasta 20,000 IOPS.
# Rendimiento de línea base (Sostenido): ~78.75 MB/s y ~3,600 IOPS.

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  #addon_version            = "v1.35.0-eksbuild.1" # Versión compatible certificada para producción en 2026
  # BUENA PRÁCTICA: Evita que parches automáticos de AWS pisen tus configuraciones
  resolve_conflicts_on_update = "PRESERVE"
  service_account_role_arn = aws_iam_role.ebs_csi_driver.arn
  tags = local.common_tags

  # OBLIGATORIO: El Add-on necesita que los nodos Spot ya existan y estén Ready
  depends_on = [aws_eks_node_group.private_nodes, aws_iam_role_policy_attachment.ebs_csi_policy]
}

# creamos el recurso StorageClass de Kubernetes usando Terraform y lo marcamos como la clase por defecto del sistema
resource "kubernetes_storage_class_v1" "gp3_default" {
  #provider = kubernetes.aws_eks
  metadata {
    name = "gp3"
    annotations = { "storageclass.kubernetes.io/is-default-class" = "true" }
  }

  # Indicamos que el traductor oficial es el driver que acabamos de instalar
  storage_provisioner    = "ebs.csi.aws.com"
  # Automatic removal of disk when PVC are deleted
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


/*
#### EFS ####

# 1. Security Group para EFS (permite NFS puerto 2049 desde los nodos de EKS)
resource "aws_security_group" "efs" {
  name        = "${var.environment}-efs-sg"
  description = "Security group for Amazon EFS shared storage"
  vpc_id      = var.vpc.vpc_id

  ingress {
    description     = "NFS inbound from EKS worker nodes"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_nodes.id]
  }

  tags = local.common_tags
}

# 2. File System de Amazon EFS
resource "aws_efs_file_system" "main" {
  creation_token = "${var.environment}-eks-efs"
  encrypted      = true

  # generalPurpose: máximo de 35,000 IOPS por sistema de archivos
  # maxIO: Diseñado específicamente para escalar a miles de clientes o pods conectados
  performance_mode = "generalPurpose"  # cant be changed after creation

  # bursting: Permite acumular "créditos de ráfaga"
  # provisoned : provisioned_throughput_in_mibps en Terraform (por ejemplo, 100 para 100 MiB/s).
  # elastic: El rendimiento escala y disminuye de forma totalmente automática, hasta 3 GiB/s para lectura y 1 GiB/s para escritura por sistema de archivos
  throughput_mode  = "bursting"  #both provisioned together with provisioned_throughput_in_mibps or elastic

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS" # Ahorro FinOps: mueve archivos poco usados a Infrequent Access
  }

  tags = merge(local.common_tags, {
    Name = "${var.environment}-shared-efs"
  })
}

# 3. Puntos de Montaje (Mount Targets) en cada Subnet Privada
resource "aws_efs_mount_target" "zone" {
  for_each        = toset(var.vpc.private_subnet_ids)
  file_system_id  = aws_efs_file_system.main.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

# 4. Rol IAM con Trust Policy hacia la ServiceAccount de EFS CSI Driver
resource "aws_iam_role" "efs_csi_driver" {
  name        = "${var.environment}-efs-csi-driver-role"
  description = "Permisos IAM para que el driver de Kubernetes gestione Amazon EFS"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.eks.oidc_issuer}:sub" = "system:serviceaccount:kube-system:efs-csi-controller-sa"
          "${var.eks.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

# 5. Adjuntar la política administrada por AWS para EFS CSI
resource "aws_iam_role_policy_attachment" "efs_csi_policy" {
  role       = aws_iam_role.efs_csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}

# 6. EKS Addon oficial de AWS para EFS
resource "aws_eks_addon" "efs_csi" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-efs-csi-driver"
  resolve_conflicts_on_update = "PRESERVE"
  service_account_role_arn = aws_iam_role.efs_csi_driver.arn

  tags = local.common_tags

  depends_on = [
    aws_eks_node_group.private_nodes,
    aws_iam_role_policy_attachment.efs_csi_policy
  ]
}

# 7. StorageClass de Kubernetes para EFS
resource "kubernetes_storage_class_v1" "efs_sc" {
  #provider = kubernetes.aws_eks

  metadata {name = "efs-sc"}

  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Delete"

  parameters = {
    provisioningMode = "efs-ap" # Crea un EFS Access Point automáticamente por cada PVC
    fileSystemId     = aws_efs_file_system.main.id
    directoryPerms   = "700"
  }

  depends_on = [
    aws_eks_addon.efs_csi,
    aws_efs_mount_target.zone
  ]
}


#### S3 #####

# 1. Addon oficial de AWS Mountpoint para S3
resource "aws_eks_addon" "s3_csi" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-mountpoint-s3-csi-driver"
  resolve_conflicts_on_update = "PRESERVE"
  tags = local.common_tags
  depends_on = [aws_eks_node_group.private_nodes]
}

# For each application


# 1. Bucket S3 para datos de aplicaciones / plataforma
resource "aws_s3_bucket" "app_data" {
  bucket        = "${var.environment}-app-shared-data-${var.aws_region}"
  force_destroy = var.environment != "prod"
  tags = local.common_tags
}

# 2. Bloqueo de acceso público y cifrado
resource "aws_s3_bucket_public_access_block" "app_data" {
  bucket                  = aws_s3_bucket.app_data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app_data" {
  bucket = aws_s3_bucket.app_data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

3. # Rol exclusivo para la aplicación "orders-service" en el namespace "dev"
resource "aws_iam_role" "app_s3_role" {
  name = "${var.environment}-orders-service-s3-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.eks_oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          # Restricción estricta: solo la ServiceAccount 'orders-sa' del namespace 'dev'
          "${var.eks.oidc_issuer}:sub" = "system:serviceaccount:${var.app_namespace}:${var.service_account_name}"
          "${var.eks.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

4. # Permisos limitados estrictamente a su bucket
resource "aws_iam_policy" "app_s3_policy" {
  name = "${var.environment}-orders-service-s3-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject"
      ]
      Resource = "${aws_s3_bucket.app_bucket.arn}/*"
    }]
  })
}

5.  Asociacion de poliza
resource "aws_iam_role_policy_attachment" "s3_csi_attach" {
  role       = aws_iam_role.app_s3_role.name
  policy_arn = aws_iam_policy.app_s3_policy.arn
}*/

