# 1. IAM Role &  Policies for EKS Control Plane
resource "aws_iam_role" "eks_cluster" {
  name = "eks-cluster-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "eks.amazonaws.com" } }]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"])
  policy_arn = each.value
  role       = aws_iam_role.eks_cluster.name
}


# Clave KMS dedicada para el cifrado de Secretos en EKS
resource "aws_kms_key" "eks_secrets" {
  description             = "KMS key for EKS secrets envelope encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags = local.common_tags
}

resource "aws_kms_alias" "eks_secrets_alias" {
  name          = "alias/${var.environment}-eks-secrets-key"
  target_key_id = aws_kms_key.eks_secrets.key_id
}

# 2. EKS Control Plane
resource "aws_eks_cluster" "main" {
  name     = "${var.environment}-aws-cluster"
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = var.vpc.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP" # Te permite usar ambos métodos a la vez
    bootstrap_cluster_creator_admin_permissions = true # Mantiene a tu usuario actual como administrador
  }

  encryption_config {
    provider { key_arn = aws_kms_key.eks_secrets.arn }
    resources = ["secrets"]
  }

  tags = local.common_tags
  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policies]
}

# 3. IAM Role & Policies for EKS Worker Node group

# 3.1 Trust role for ec2 service
resource "aws_iam_role" "eks_nodes" {
  name = "eks-node-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
  tags = local.common_tags
}

# 3.2 Attach required ec2 policies
resource "aws_iam_role_policy_attachment" "node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" # 👈 ESTÁNDAR: Permite acceso por SSM sin SSH
  ])
  policy_arn = each.value
  role       = aws_iam_role.eks_nodes.name
}


# 4.1 Launch Template para los nodos, asignamos SG
resource "aws_launch_template" "eks_nodes" {
  name_prefix   = "${var.environment}-eks-node-template"
  description   = "Launch template for EKS worker nodes with custom SG"

  vpc_security_group_ids = [
    aws_security_group.eks_nodes.id,
    aws_eks_cluster.main.vpc_config[0].cluster_security_group_id # Mantiene también el SG por defecto de EKS
  ]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # Obliga a usar IMDSv2
    http_put_response_hop_limit = 2          # Requerido si usas Pods con VPC CNI
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.common_tags, { Name = "${var.environment}-eks-node" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.common_tags, { Name = "${var.environment}-eks-node-ebs" })
  }
}

# 4.2 EKS Node Group
resource "aws_eks_node_group" "private_nodes" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "private-workers"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = var.vpc.private_subnet_ids

  capacity_type  = var.eks.node_capacity_type
  instance_types = var.eks.node_instance_types


  # 🎯 VINCULACIÓN DEL LAUNCH TEMPLATE CON EL SG
  launch_template {
    name    = aws_launch_template.eks_nodes.name
    version = aws_launch_template.eks_nodes.latest_version
  }

  scaling_config {
    desired_size = var.eks.desired_size
    max_size     = var.eks.max_size
    min_size     = var.eks.min_size
  }

  # REGLAS DE ACTUALIZACIÓN SEGURA Y ALTA DISPONIBILIDAD (no mas de un nodo concurrent update)
  update_config {
    max_unavailable = 1 # O un porcentaje como "33%"
  }

  tags = merge(
    local.common_tags,
    {
      # Group owned by the cluster
      "kubernetes.io/cluster/${aws_eks_cluster.main.name}" = "owned"
      # Enable scaling via cluster-autoscaler
      "k8s.io/cluster-autoscaler/enabled"                  = "true"
      # Owned by cluster-autoscaler running in specified cluster
      "k8s.io/cluster-autoscaler/${aws_eks_cluster.main.name}" = "owned"
      # Zone info for cluster-autoscaler before creating node to scale based on topology or affinity constrains
      "k8s.io/cluster-autoscaler/node-template/label/topology.kubernetes.io/zone" = ""
    }
  )

  depends_on = [aws_iam_role_policy_attachment.node_policies]
}

# 5. VPC CNI Addon (Supports Security Groups for Pods)
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"
  resolve_conflicts_on_update = "OVERWRITE"
  resolve_conflicts_on_create = "OVERWRITE"
  configuration_values = jsonencode({

    env = {
      ENABLE_POD_ENI = var.eks.enable_pod_eni ? "true" : "false"
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET       = "1"
    }
  })

  tags = local.common_tags
}


# 6.1. Optional DevOps Access Entry
resource "aws_eks_access_entry" "devops_team" {
  count         = var.devops_role_arn != null ? 1 : 0
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.devops_role_arn
  type          = "STANDARD"
}

# 6.2. Link AmazonEKSClusterAdminPolicy with the previous access entry for Devops Team Role
resource "aws_eks_access_policy_association" "devops_admin" {
  count         = var.devops_role_arn != null ? 1 : 0
  cluster_name  = aws_eks_cluster.main.name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy" ## This will map devops role into system-admins K8s group
  principal_arn = aws_eks_access_entry.devops_team[0].principal_arn

  access_scope {
    type = "cluster"
  }
}


# 7.1. EKS API Control Admission (safeguard)
/*resource "kubernetes_manifest" "enforce_gitops_workloads" {
  manifest = {
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicy"
    metadata = {
      name = "enforce-gitops-workloads"
    }
    spec = {
      failurePolicy = "Fail"
      matchConstraints = {
        resourceRules = [
          {
            apiGroups   = ["apps"]
            apiVersions = ["v1"]
            resources   = ["deployments", "statefulsets", "daemonsets"]
            operations  = ["CREATE", "UPDATE"]
          },
          {
            apiGroups   = ["batch"]
            apiVersions = ["v1"]
            resources   = ["jobs", "cronjobs"]
            operations  = ["CREATE", "UPDATE"]
          },
          {
            apiGroups   = [""]
            apiVersions = ["v1"]
            resources   = ["pods"]
            operations  = ["CREATE"]
          }
        ]
      }

      validations = [
        {
          expression = <<-CEL
            // 1. Permitir siempre a ArgoCD (vía EKS Access Entry group o ServiceAccount)
            ('argocd:business-operators' in request.userInfo.groups)
            || ('system:serviceaccounts:argocd' in request.userInfo.groups)

            // 2. Permitir a Break-Glass / Admins de infraestructura
            || ('system:masters' in request.userInfo.groups)

            // 3. Permitir a los controladores internos nativos de K8s (¡vital para que funcionen los Deployments/Pods!)
            || (request.userInfo.username.startsWith('system:kube-controller-manager'))
            || (request.userInfo.username.startsWith('system:node:'))
            || ('system:nodes' in request.userInfo.groups)

            // 4. Permitir a herramientas de plataforma/escalado (ej. Karpenter, operadores del sistema)
            || request.userInfo.groups.exists(g, g in [
                 'system:serviceaccounts:karpenter',
                 'system:serviceaccounts:kube-system'
               ])
          CEL
          message    = "GitOps Enforcement: Direct creation or mutation of workloads is forbidden. All deployments must originate via ArgoCD."
        }
      ]
    }
  }
}

# 7.2. Bind Previous admission policy to a Deny action
resource "kubernetes_manifest" "admission_policy_binding" {
  manifest = {
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicyBinding"
    metadata = { name = "block-system-namespace-mutation-binding" }
    spec = {
      policyName        = kubernetes_manifest.enforce_gitops_workloads.manifest.metadata.name
      # En producción: empieza con ["Warn", "Audit"] y cuando verifiques que ArgoCD opera sin fallos, pasa a ["Deny"]
      validationActions = ["Deny"]
      matchResources = { namespaceSelector = {} }
    }
  }
}
*/
# 8. Get the TLS certificate thumbprint of the EKS OIDC Issuer URL
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# 9. Create the OIDC Provider
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# 10. Security Group para los Nodos de EKS
resource "aws_security_group" "eks_nodes" {
  name        = "eks-nodes-sg"
  description = "Security group for EKS worker nodes"
  vpc_id      = var.vpc.vpc_id

  tags = merge(
    local.common_tags,
    #{
    #  "kubernetes.io/cluster/${aws_eks_cluster.main.name}" = "owned"
    #}
  )
}

# 11. Security Group Rules
# Permite que las peticiones nacidas en los nodos worker alcancen el endpoint del Control Plane de EKS
resource "aws_security_group_rule" "eks_nodes_to_control_plane" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  description              = "Permite el trafico HTTPS desde los nodos worker hacia la API del Control Plane"
  security_group_id        = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  source_security_group_id = aws_security_group.eks_nodes.id
}


resource "aws_security_group_rule" "ingress_premises" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.eks_nodes.id
  cidr_blocks       = [var.premises.on_prem_cidr]
}

resource "aws_security_group_rule" "egress_premises" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.eks_nodes.id
  cidr_blocks       = [var.premises.on_prem_cidr]
}

resource "aws_security_group_rule" "egress_http" {
  type              = "egress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  security_group_id = aws_security_group.eks_nodes.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "egress_https" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.eks_nodes.id
  cidr_blocks = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "egress_dns_tcp" {
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  security_group_id = aws_security_group.eks_nodes.id
  cidr_blocks = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "egress_dns_udp" {
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  security_group_id = aws_security_group.eks_nodes.id
  cidr_blocks = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "egress_db" {
  type              = "egress"
  from_port         = aws_db_instance.postgres.port
  to_port           = aws_db_instance.postgres.port
  protocol          = "tcp"
  security_group_id = aws_security_group.eks_nodes.id
  source_security_group_id = aws_security_group.db.id
}


# 10. Security Group Exclusivo para Pods de Aplicaciónes (Pod ENI)
# NOTE: the SecurityGroupPolicy that binds pods to a dedicated ENI security
# group lives in the software layer (modules/software/pod_sg_policy.tf).
# kubernetes_manifest needs API access at plan time, which is impossible in the
# same apply that creates the cluster.
resource "aws_security_group" "pod_app_sg" {
  #count = var.eks.enable_pod_eni ? 1 : 0
  name        = "${var.environment}-pod-app-sg"
  description = "Security group applied directly to application pods via AWS VPC CNI"
  vpc_id      = var.vpc.vpc_id

  # ingress-nginx envia el trafico a la IP del pod y su containerPort, no al
  # puerto del Service, asi que este puerto debe ser el del contenedor.
  ingress {
    from_port       = var.app_container_port
    to_port         = var.app_container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_nodes.id]
    description     = "ingress-nginx controller to application pods"
  }

  egress {
    from_port       = aws_db_instance.postgres.port
    to_port         = aws_db_instance.postgres.port
    protocol        = "tcp"
    security_groups = [aws_security_group.db.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.premises.on_prem_cidr]
  }

  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # STS, ECR, Secrets Manager, etc. Sin esto los pods con ENI dedicada no
  # pueden hablar con ningun endpoint de AWS.
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}
