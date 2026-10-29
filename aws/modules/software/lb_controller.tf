# 1. IRSA role for the AWS Load Balancer Controller.
#    Same module already used for the Karpenter controller in the platform layer.
module "lb_controller_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                              = "${var.environment}-aws-lb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = var.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = local.common_tags
}

# 2. The controller itself. Required by the `aws-load-balancer-type: external`
#    annotation on the ingress-nginx Service: without it the Service is never
#    reconciled by anything and stays <pending> forever.
resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.8.1"
  namespace  = "kube-system"

  values = [
    yamlencode({
      clusterName = var.eks.cluster_name
      vpcId       = var.vpc.vpc_id
      replicaCount = 2
      priorityClassName = "system-cluster-critical"
      resources = {
        requests = {
          cpu    = "50m"
          memory = "64Mi"
        }
        limits = {
          cpu    = "100m"
          memory = "128Mi"
        }
      }
      topologySpreadConstraints = [
        {
          maxSkew           = 1
          topologyKey       = "topology.kubernetes.io/zone"
          whenUnsatisfiable = "DoNotSchedule"
          labelSelector = { matchLabels = { "app.kubernetes.io/name" = "aws-load-balancer-controller" } }
        }
      ]
      podAntiAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = [
          {
            labelSelector = {
              matchExpressions = [
                {
                  key      = "app.kubernetes.io/name"
                  operator = "In"
                  values = ["aws-load-balancer-controller"]
                }
              ]
            }
            topologyKey = "kubernetes.io/hostname"
          }
        ]
      }
      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
        annotations = {
          "eks.amazonaws.com/role-arn" = module.lb_controller_role.iam_role_arn
        }
      }
      nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
    })
  ]

  depends_on = [kubectl_manifest.karpenter_node_pool_infra]
}

