# Binds application pods to their own branch ENI carrying pod_app_sg.
#
# This lives in the software layer, not the platform layer, on purpose:
# kubernetes_manifest reads the CRD's OpenAPI schema from the API server during
# the PLAN phase, so the cluster must already exist. Here the endpoint comes
# from remote state, so it is always known at plan time.
resource "kubernetes_manifest" "pod_sg_policy" {
  count = var.enable_pod_eni ? 1 : 0
  manifest = {
    apiVersion = "vpcresources.k8s.aws/v1beta1"
    kind       = "SecurityGroupPolicy"
    metadata = {
      name      = "app-pod-security-policy"
      namespace = var.app_namespace
    }
    spec = {
      podSelector = {
        matchLabels = var.app_pod_selector_labels
      }
      securityGroups = {
        groupIds = [var.eks.pod_app_sg]
      }
    }
  }
}
