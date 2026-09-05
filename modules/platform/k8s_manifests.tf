resource "kubernetes_manifest" "pod_sg_policy" {
  manifest = {
    apiVersion = "vpcresources.k8s.aws/v1beta1"
    kind       = "SecurityGroupPolicy"
    metadata = {
      name      = "app-pod-security-policy"
      namespace = "default"
    }
    spec = {
      podSelector = {
        matchLabels = {
          role = "backend-app"
        }
      }
      securityGroups = {
        groupIds = [aws_security_group.pod_app_sg.id]
      }
    }
  }

  depends_on = [
    aws_eks_node_group.private_nodes,
    aws_eks_addon.vpc_cni
  ]
}
