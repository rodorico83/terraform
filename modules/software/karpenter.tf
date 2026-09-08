# 2. Create the IAM Role for the Karpenter Controller (IRSA)
module "karpenter_controller_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                          = "karpenter-controller"
  attach_karpenter_controller_policy = true

  karpenter_controller_cluster_id = var.eks.cluster_name
  # Required to map AWS NodeClasses to the node IAM role
  karpenter_controller_node_iam_role_arns = [
    var.eks.node_role_arn
  ]

  oidc_providers = {
    ex = {
      provider_arn               = var.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:karpenter"] # Matches the service account name
    }
  }
}


# 3. Install Karpenter CRDs (Required Before Installing the Main Chart)
resource "helm_release" "karpenter_crd" {
  namespace        = "kube-system"
  name             = "karpenter-crd"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter-crd"
  version          = "1.0.6" # 👈 Use the matching version for your stack
  create_namespace = false
}

# 4. Install Karpenter Core Controller
resource "helm_release" "karpenter" {
  namespace        = "kube-system"
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "1.0.6"
  create_namespace = false

  # Ensures CRDs exist before running the controller
  depends_on = [helm_release.karpenter_crd]

  values = [
    <<-EOT
    serviceAccount:
      create: true
      name: karpenter
      annotations:
        # Associates the IAM Role with the Service Account
        eks.amazonaws.com/role-arn: ${module.karpenter_controller_role.iam_role_arn}

    settings:
      clusterName: ${var.eks.cluster_name}
      clusterEndpoint: ${var.eks.cluster_endpoint}
      # Not required with karpenter version 1.0.0+
      #interconnect:
      #  aws:
      #    # Tells Karpenter which EKS NodeGroup IAM role to give to newly created instances
      #    defaultInstanceProfile: ${var.eks.cluster_name}-node-profile

    # Tolerations force Karpenter pods onto your locked-down system node group
    tolerations:
      - key: "CriticalAddonsOnly"
        operator: "Exists"
      - key: "nas-system-nodes"
        operator: "Exists"
        effect: "NoSchedule"
    EOT
  ]
}

# 5. Configuración de AWS para los nuevos nodos creados por Karpenter
resource "kubernetes_manifest" "karpenter_node_class" {
  provider = kubernetes.aws_eks

  manifest = {
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "default"
    }
    spec = {
      # 🔍 Busca automáticamente tus subnets y Security Groups usando el nombre del clúster
      subnetSelectorTerms = [
        { tags = { "kubernetes.io/cluster/${var.eks.cluster_name}" = "shared" } }
      ]
      securityGroupSelectorTerms = [
        { tags = { "kubernetes.io/cluster/${var.eks.cluster_name}" = "owned" } }
      ]

      # 🔑 Usamos la variable que ya tienes en tu módulo para vincular el rol de los nodos
      role = var.eks.node_role_arn

      # Sistema operativo optimizado para EKS (Soporta x86 y ARM de forma nativa)
      amiFamily = "AL2023"
    }
  }

  depends_on = [helm_release.karpenter]
}

# 6. Definición del NodePool con la estrategia de bajo coste condicional
resource "kubernetes_manifest" "karpenter_node_pool" {
  provider = kubernetes.aws_eks

  manifest = {
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "low-cost-pool"
    }
    spec = {
      template = {
        spec = {
          requirements = [
            # 💡 AUTOMATIZACIÓN DE COSTES:
            # Si var.environment es "prod", usa "on-demand". Si es "dev"/"stage", usa "spot" (70% ahorro).
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = [var.environment == "prod" ? "on-demand" : "spot"]
            },
            # Permite tanto nodos tradicionales (amd64) como los económicos Graviton (arm64)
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64", "arm64"]
            },
            # Restringimos el parque de servidores a las familias más baratas y eficientes de AWS
            {
              key      = "node.kubernetes.io/instance-type"
              operator = "In"
              values   = ["t4g.medium", "t4g.large", "t3a.medium", "t3a.large", "c6g.large", "m6a.large"]
            }
          ]
          # Vinculación con la clase de AWS definida arriba
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
        }
      }
      # Límites de seguridad para evitar que el autoescalado crezca infinitamente por error
      limits = {
        cpu    = "20"
        memory = "40Gi"
      }
      disruption = {
        consolidationPolicy = "WhenUnderutilized"
        expireAfter         = "720h"
      }
    }
  }

  depends_on = [kubernetes_manifest.karpenter_node_class]
}

# 6. 🏷️ Inyectamos dinámicamente el tag de Karpenter en las Subnets de la Capa 1
resource "aws_ec2_tag" "karpenter_subnet_tags" {
  # Recorre cada una de las subnets privadas de tu lista
  for_each    = toset(var.vpc.private_subnet_ids)
  resource_id = each.value

  key   = "kubernetes.io/cluster/${var.eks.cluster_name}"
  value = "shared"
}

# 7. 🏷️ Inyectamos dinámicamente el tag en el Security Group de la Capa 2
resource "aws_ec2_tag" "karpenter_sg_tag" {
  resource_id = var.eks.cluster_sg

  key   = "kubernetes.io/cluster/${var.eks.cluster_name}"
  value = "owned"
}