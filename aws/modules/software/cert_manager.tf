# Cert-Manager
resource "helm_release" "cert_manager" {
  count            = var.enable_cert_manager ? 1 : 0
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.14.0"
  namespace        = "cert-manager"
  create_namespace = true

  set {
    name  = "installCRDs"
    value = "true"
  }

  values = [
    yamlencode({
      # Controller : bucle reconciliación de CRD´s, Solicitud y Renovación certs, Emisión y almacenamiento en secrets
      nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
      resources = {
        requests = {
          cpu    = "50m"
          memory = "128Mi"
        }
        limits = {
          cpu    = "100m"
          memory = "200Mi"
        }
      }
      # Validating and Mutating Admission Webhook Comprueba  recursos YAML (Certificate, Issuer, ClusterIssuer)
      webhook = {
        nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
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
      }
      # Inyecta los certificados de las Autoridades de Certificación (CA) en (ValidatingWebhookConfiguration, MutatingWebhookConfiguration, CustomResourceDefinition ...) .
      cainjector = {
        nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" }
        resources = {
          requests = {
            cpu    = "50m"
            memory = "128Mi"
          }
          limits = {
            cpu    = "100m"
            memory = "200Mi"
          }
        }
      }
    })
  ]
  depends_on = [helm_release.nginx_ingress,kubectl_manifest.karpenter_node_pool_infra]
}

resource "kubectl_manifest" "letsencrypt_cluster_issuer" {
  count = var.enable_cert_manager ? 1 : 0

  yaml_body = <<YAML
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-${var.environment}
spec:
  acme:
    server : "https://acme-v02.api.letsencrypt.org/directory"
    email: contact@rj-engineering.com
    privateKeySecretRef:
      name: letsencrypt-${var.environment}-account-key
    # define cómo cert-manager le demuestra a Let's Encrypt que tú eres el verdadero propietario del dominio antes de emitir el certificado SSL
    # a traves de reto ACME y generacion temporal de regla y pod efimero para la validacoin
    solvers:
    - http01:
        ingress:
          ingressClassName: nginx
YAML

  # Evita que el plan falle al no encontrar la definición del CRD en el clúster vacío
  validate_schema = false
  force_new       = true

  # CRÍTICO: Espera a que el Helm con índice correspondiente se instale
  depends_on = [helm_release.cert_manager]
}