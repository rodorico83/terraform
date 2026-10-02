# 1. Definimos la política con los permisos faltantes para Karpenter v1
# ==============================================================================
# 1. POLÍTICA IAM COMPLETA PARA EL CONTROLADOR DE KARPENTER v1.x (CORREGIDA)
# ==============================================================================
resource "aws_iam_policy" "karpenter_iam_policy" {
  name        = "karpenter-iam-policies"
  description = "Permisos completos de ciclo de vida EC2 e IAM requeridos por Karpenter v1"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # A) Gestión de Instancias EC2 y Launch Templates (Corrige el error de la imagen)
      {
        Effect   = "Allow"
        Action   = [
          "ec2:RunInstances",
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate",
          "ec2:DeleteLaunchTemplate",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
          "ec2:DescribeTags",
          "ec2:TerminateInstances"
        ]
        Resource = "*"
      },
      # B) Permisos para inyectar etiquetas a las nuevas instancias creadas
      {
        Effect   = "Allow"
        Action   = [
          "ec2:CreateTags"
        ]
        Resource = "arn:aws:ec2:*:*:instance/*"
      },
      # C) Gestión de Instance Profiles para pasarle el rol a los nodos elásticos
      {
        Effect   = "Allow"
        Action   = [
          "iam:GetInstanceProfile",
          "iam:CreateInstanceProfile",
          "iam:TagInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:DeleteInstanceProfile"
        ]
        Resource = "*"
      },
      # D) Permiso para pasar el Rol de Nodo de EKS a EC2 (PassRole)
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = var.eks.node_role_arn
      },
      # E) Consulta del catálogo de AMIs optimizadas de Amazon (SSM)
      {
        Effect   = "Allow"
        Action   = [
          "ssm:GetParameter"
        ]
        Resource = "arn:aws:ssm:*:*:parameter/aws/service/ami-amazon-linux-latest/*"
      }
    ]
  })
}

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

  role_policy_arns = {
    karpenter_fixes = aws_iam_policy.karpenter_iam_policy.arn
  }

  oidc_providers = {
    ex = {
      provider_arn               = var.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:karpenter"] # Matches the service account name
    }
  }
}

resource "aws_iam_service_linked_role" "spot" {
  aws_service_name = "spot.amazonaws.com"

  # Este bloque evita que falle si el rol ya existía previamente en tu cuenta de AWS
  lifecycle {
    ignore_changes = all
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

  values = [
    <<-EOT
    serviceAccount:
      create: true
      name: karpenter
      annotations:
        # Associates the IAM Role with the Service Account
        eks.amazonaws.com/role-arn: ${module.karpenter_controller_role.iam_role_arn}

    # ------------------------------------------------------------------------
    # FORZAR A KARPENTER A CORRER EXCLUSIVAMENTE EN EL MANAGED NODE GROUP BASE
    # ------------------------------------------------------------------------
    nodeSelector:
      # "private-workers" es el node_group_name declarado en eks.tf
      eks.amazonaws.com/nodegroup: "private-workers"

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

  # Ensures CRDs exist before running the controller
  depends_on = [helm_release.karpenter_crd]
}

# 5. Configuración de AWS para los nuevos nodos creados por Karpenter
resource "kubectl_manifest" "karpenter_node_class" {

  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "default-v2"
    }
    spec = {
      # 🔍 Busca automáticamente tus subnets y Security Groups usando el nombre del clúster
      subnetSelectorTerms = [
        { tags = { "kubernetes.io/cluster/${var.eks.cluster_name}" = "shared" } }
      ]
      /*securityGroupSelectorTerms = [
        { tags = { "kubernetes.io/cluster/${var.eks.cluster_name}" = "owned" } }
      ]*/

      securityGroupSelectorTerms = [
        { id = var.eks.node_sg },   # Tu SG personalizado de nodos
        { id = var.eks.cluster_sg } # SG por defecto de EKS
      ]

      # 🔑 Usamos la variable que ya tienes en tu módulo para vincular el rol de los nodo
      # 🔑 ESTÁNDAR KARPENTER V1: Exige el NOMBRE plano del rol, NO el ARN completo.
      # Esta función corta "arn:aws:iam::123:role/karpenter-node-role" y extrae solo "karpenter-node-role"
      role = element(split("/", var.eks.node_role_arn), length(split("/", var.eks.node_role_arn)) - 1)

      # Sistema operativo optimizado para EKS (Soporta x86 y ARM de forma nativa), Not valid for Karpenter version > 1
      amiSelectorTerms = [
        { alias = "al2023@latest" } # 👈 Esto le indica a AWS que busque la versión más nueva de Amazon Linux 2023 sin amarrarse a la v1.36 específica que fallaba
      ]


      metadataOptions = {
        httpEndpoint = "enabled"
        httpProtocolIPv6 = "disabled"
        httpTokens = "required"      # <--- ESTO OBLIGA A USAR IMDSv2 (Desactiva v1)
        httpPutResponseHopLimit: 2   # Permite que el token pase del nodo al Pod de K8s de forma segura
      }

    }
  })

  depends_on = [helm_release.karpenter]
}

# ==============================================================================
# PRIORITY CLASSES PARA GESTIÓN DE PREEMPTION Y DAEMONSETS CON KARPENTER
# ==============================================================================

# Prioridad Alta para DaemonSets (Fuerza el desalojo de pods de negocio)
/*resource "kubectl_manifest" "priority_class_daemonsets" {
  yaml_body = yamlencode({
    apiVersion    = "scheduling.k8s.io/v1"
    kind          = "PriorityClass"
    metadata = {
      name = "daemonset-high-priority"
    }
    value         = 900000
    globalDefault = false
    description   = "Prioridad alta para forzar desalojo de pods de negocio cuando un DaemonSet entra en el nodo."
  })
}*/

# Prioridad Por Defecto para Cargas de Trabajo / Negocio
resource "kubectl_manifest" "priority_class_workloads" {
  yaml_body = yamlencode({
    apiVersion    = "scheduling.k8s.io/v1"
    kind          = "PriorityClass"
    metadata = {
      name = "workload-medium-priority"
    }
    value         = 100000
    globalDefault = true # Todos los pods sin priorityClassName explícito tomarán este valor
    description   = "Prioridad base por defecto para Deployments de aplicaciones de negocio."
  })
}


# 6. Definición del NodePool con la estrategia de bajo coste condicional
resource "kubectl_manifest" "karpenter_node_pool" {
  #provider = kubernetes.aws_eks

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "low-cost-pool"
    }
    spec = {
      template = {
        spec = {
          # Max number of pods per node and reserve for system pods (daemonsets)
          kubelet = {
            maxPods = 110 # Si usas Prefix Delegation
            systemReserved = {
              cpu    = "150m"
              memory = "256Mi"
            }
          }
          requirements = [
            # 💡 AUTOMATIZACIÓN DE COSTES:
            # Permitir todas las zonas de la región (ej. eu-south-2)
            {
              key      = "topology.kubernetes.io/zone"
              operator = "In"
              values   = ["eu-south-2a", "eu-south-2b", "eu-south-2c"]
            },
            # Si var.environment es "prod", usa "on-demand". Si es "dev"/"stage", usa "spot" (70% ahorro).
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = [var.environment == "prod" ? "on-demand" : "spot"]
              #values   = ["spot" , "on-demand"]
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
              values   = [ "t3.large", "t3.medium", "t4g.medium" , "t4g.large" ]
              #values   = ["t4g.medium", "t4g.large", "t3a.medium", "t3a.large", "c6g.large", "m6a.large"]
            }
          ]
          # Vinculación con la clase de AWS definida arriba
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default-v2"
          }
        }
      }
      # Límites de seguridad para evitar que el autoescalado crezca infinitamente por error
      limits = {
        cpu    = "20"
        memory = "32Gi"
      }
      disruption = {
        # Consolida nodos vacíos o infrautilizados de forma combinada
        consolidationPolicy = "WhenEmptyOrUnderutilized"

        # OBLIGATORIO V1: Tiempo de espera para ejecutar la fusión (ej: 1 minuto)
        # En desarrollo "1m" es ideal para ver la magia de ahorro rápido en acción
        consolidateAfter = "10m"

        # Caducidad obligatoria del nodo para parches de seguridad (30 días)
        expireAfter = "720h"
      }
    }
  })

  depends_on = [kubectl_manifest.priority_class_workloads ]
}

# 6. 🏷️ Inyectamos dinámicamente el tag de Karpenter en las Subnets de la Capa 1
resource "aws_ec2_tag" "karpenter_subnet_tags" {
  # Recorre cada una de las subnets privadas de tu lista
  for_each    = toset(var.vpc.private_subnet_ids)
  resource_id = each.value

  key   = "kubernetes.io/cluster/${var.eks.cluster_name}"
  value = "shared"
}

/*
# 7. 🏷️ Inyectamos dinámicamente el tag en el Security Group de la Capa 2
# No necesario el link se ha hecho en el karpenter_node_class
resource "aws_ec2_tag" "karpenter_sg_tag" {
  resource_id = var.eks.cluster_sg

  key   = "kubernetes.io/cluster/${var.eks.cluster_name}"
  value = "owned"
}*/