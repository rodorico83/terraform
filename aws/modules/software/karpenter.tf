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

# Allow the request of SPOT nodes
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
  wait   = true
  atomic = true
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
    yamlencode({
      replicaCount = 1
      #podDisruptionBudget = { maxUnavailable = 1 }

      # 🎯 Notificación de eventos EC2/Spot mediante SQS (recomendado to detect shutdown by maintenance)
      # interruptionQueue = var.karpenter_sqs_queue_name

      priorityClassName = "system-cluster-critical"

      /*topologySpreadConstraints = [
        {
          maxSkew           = 1
          topologyKey       = "topology.kubernetes.io/zone"
          whenUnsatisfiable = "ScheduleAnyway"
          labelSelector = {
            matchLabels = { "app.kubernetes.io/name" = "karpenter" }
          }
        }
      ]*/
      serviceAccount = {
        create = true
        name   = "karpenter"
        annotations = { "eks.amazonaws.com/role-arn" = module.karpenter_controller_role.iam_role_arn }
      }
      nodeSelector = { "eks.amazonaws.com/nodegroup" = "private-workers" }
      controller = {
        resources = {
          requests = {
            cpu    = "75m"
            memory = "400Mi"
          }
          limits = {
            cpu    = "300m"
            memory = "700Mi"
          }
        }
      }

      settings = {
        clusterName     = var.eks.cluster_name
        clusterEndpoint = var.eks.cluster_endpoint
        # Allow karpenter to replace Spot node for a cheaper Spot node type if available nd suitable
        featureGates = { spotToSpotConsolidation = true }
      }

      # Tolerations force Karpenter pods onto your locked-down system node group
      tolerations = [
        {
          key      = "CriticalAddonsOnly"
          operator = "Exists"
        },
        {
          key      = "nas-system-nodes"
          operator = "Exists"
          effect   = "NoSchedule"
        }
      ]
    })
  ]
  # Ensures CRDs exist before running the controller
  depends_on = [helm_release.karpenter_crd]
}

# 5. Configuración de AWS para los nuevos nodos creados por Karpenter
resource "kubectl_manifest" "karpenter_node_class" {

  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = { name = "default-v3" }
    spec = {
      # 🔍 Busca automáticamente tus subnets y Security Groups usando el nombre del clúster
      subnetSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = var.eks.cluster_name } }
      ]

      # SG Selection via tag or via Id
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
        { alias = "al2023@latest" } # Other option bottlerocket@latest (ssoo ultraligero diseñado por AWS exclusivamente para correr contenedores)
      ]
      kubelet = {
        maxPods = 110
        systemReserved = {
          cpu    = "50m"
          memory = "128Mi"
        }
      }
      # root system disk configuration
      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = { # These are actually the default values except for volume size which is usuarlly 20GB
            volumeSize          = "20Gi"
            volumeType          = "gp3"
            iops                = 3000
            throughput          = 125
            encrypted           = true
            deleteOnTermination = true
          }
        }
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


# Prioridad Por Defecto para Cargas de Trabajo / Negocio
# system-node-critical and system-cluster-critical are avilable by default
resource "kubectl_manifest" "priority_class_workloads" {
  yaml_body = yamlencode({
    apiVersion    = "scheduling.k8s.io/v1"
    kind          = "PriorityClass"
    metadata = { name = "workload-medium-priority" }
    value         = 100000
    globalDefault = true # Todos los pods sin priorityClassName explícito tomarán este valor
    description   = "Prioridad base por defecto para Deployments de aplicaciones de negocio."
  })
}


# Definición del NodePool con la estrategia de bajo coste condicional
resource "kubectl_manifest" "karpenter_node_pool" {
  #provider = kubernetes.aws_eks

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = { name = "low-cost-pool" }
    spec = {
      template = {
        spec = {
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
              # medium 2 CPU 4GB RAM, Red 5 Gbps, Baseline 2,000 IOPS, 11,800 IOPS
              # large  2 CPU 8GB RAM, Red 5 Gbps, Baseline 4,000 IOPS, 15,700 IOPS
              # xlarge 4 CPU 16GB RAM, Red 5 Gbps,  8000/23000 IPS
              values   = [ "t3.large", "t3.medium", "t4g.medium" , "t4g.large" ]
              #values   = ["t4g.medium", "t4g.large", "t3a.medium", "t3a.large", "c6g.large", "m6a.large"]
            }
          ]
          # Vinculación con la clase de AWS definida arriba
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default-v3"
          }
        }
      }
      # Límites de seguridad para evitar que el autoescalado crezca infinitamente por error
      limits = {
        cpu    = "8"
        memory = "24Gi"
      }
      disruption = {
        # Consolida nodos vacíos o infrautilizados de forma combinada
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        # Tiempo de espera para ejecutar la fusión (ej: 1 minuto)
        consolidateAfter = "1m"
        # Caducidad obligatoria del nodo para parches de seguridad (30 días)
        expireAfter = "720h"

        /*budgets = [
          # PROHIBIR desaprovisionamientos/consolidaciones las 8 siguientes horas a las 9:00 AM
          {
            schedule = "0 9 * * mon-fri"
            duration = "8h"
            nodes    = "0"
          },
          # Permitir consolidaciones de máximo el 10% de los nodos simultáneamente
          { nodes    = "10%" }
        ]*/
      }
    }
  })

  depends_on = [kubectl_manifest.priority_class_workloads ]
}


resource "kubectl_manifest" "karpenter_node_pool_infra" {
  #provider = kubernetes.aws_eks

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = { name = "low-cost-pool-infra" }
    spec = {
      template = {
        spec = {
          metadata = {
            labels = { "workload-type" = "infrastructure" }
            # Anotación para proteger los nodos frente a la disrupción/consolidación de Karpenter
            annotations = { "karpenter.sh/do-not-disrupt" = "true" }
          }
          requirements = [
            # 💡 AUTOMATIZACIÓN DE COSTES:
            # Permitir todas las zonas de la región (ej. eu-south-2)
            {
              key      = "topology.kubernetes.io/zone"
              operator = "In"
              values   = ["eu-south-2a", "eu-south-2b"]
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
              #values   = [ "t3.large", "t3.medium", "t4g.medium" , "t4g.large" ]
              values   = ["t3.medium","t4g.medium","t4g.large","t3.large","t4g.xlarge","t3.xlarge"]
            }
          ]
          # Vinculación con la clase de AWS definida arriba
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default-v3"
          }
        }
      }
      # Límites de seguridad para evitar que el autoescalado crezca infinitamente por error
      limits = {
        cpu    = "18"
        memory = "48Gi"
      }
      disruption = {
        # Consolida nodos vacíos o infrautilizados de forma combinada
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        # Tiempo de espera para ejecutar la fusión (ej: 1 minuto)
        consolidateAfter = "1m"
        # Caducidad obligatoria del nodo para parches de seguridad (30 días)
        expireAfter = "720h"

        budgets = [
          # PROHIBIR desaprovisionamientos/consolidaciones las 8 siguientes horas a las 9:00 AM
          {
            schedule = "0 9 * * mon-fri"
            duration = "8h"
            nodes    = "0"
          },
          # Permitir consolidaciones de máximo el 10% de los nodos simultáneamente
          { nodes    = "10%" }
        ]
      }
    }
  })

  depends_on = [kubectl_manifest.priority_class_workloads ]
}


# 6. 🏷️ Inyectamos dinámicamente el tag de Karpenter en las Subnets de la Capa 1
resource "aws_ec2_tag" "karpenter_subnet_tags" {
  for_each    = toset(var.vpc.private_subnet_ids)
  resource_id = each.value
  key   = "karpenter.sh/discovery"
  value = var.eks.cluster_name
}

/*
# 7. 🏷️ Inyectamos dinámicamente el tag en el Security Group de la Capa 2
# No necesario el link se ha hecho en el karpenter_node_class
resource "aws_ec2_tag" "karpenter_sg_tag" {
  resource_id = var.eks.cluster_sg

  key   = "kubernetes.io/cluster/${var.eks.cluster_name}"
  value = "owned"
}*/