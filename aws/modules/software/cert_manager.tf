# 4. Cert-Manager
resource "helm_release" "cert_manager" {
  count            = var.enable_cert_manager ? 1 : 0
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.14.0"
  namespace        = "cert-manager"
  create_namespace = true

  set {
    #name  = "crds.enabled"
    name  = "installCRDs"
    value = "true"
  }

  values = [
    yamlencode({
      nodeSelector = {
        "eks.amazonaws.com/nodegroup" = "private-workers"
      }
      webhook = {
        nodeSelector = {
          "eks.amazonaws.com/nodegroup" = "private-workers"
        }
      }
      cainjector = {
        nodeSelector = {
          "eks.amazonaws.com/nodegroup" = "private-workers"
        }
      }
    })
  ]

}

/*# 5. ClusterIssuer enlazado al ciclo de vida de Cert-Manager
resource "kubernetes_manifest" "letsencrypt_cluster_issuer" {
  #provider = kubernetes.aws_eks

  # Hereda el count: si deshabilitas cert-manager, este recurso tampoco se creará
  count = var.enable_cert_manager ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-${var.environment}" # El que busca tu archivo Ingress
    }
    spec = {
      acme = {
        server = "https://acme-v02.api.letsencrypt.org/directory"
        #server = var.environment == "prod" ? "https://acme-v02.api.letsencrypt.org/directory" : "https://acme-staging-v02.api.letsencrypt.org/directory"
        email  = "contact@rj-engineering.com" # Cambia esto por tu correo real
        privateKeySecretRef = {
          name = "letsencrypt-${var.environment}-account-key"
        }
        solvers = [
          {
            http01 = {
              ingress = {
                ingressClassName = "nginx" # Tu controlador NGINX resolverá el reto web
              }
            }
          }
        ]
      }
    }
  }

  # CRÍTICO: Fuerza a Terraform a esperar que el Helm de arriba
  # esté 100% instalado y con los CRDs activos antes de lanzar este YAML.
  depends_on = [helm_release.cert_manager]
}*/

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
    solvers:
    - http01:
        ingress:
          ingressClassName: nginx
YAML

  # Evita que el plan falle al no encontrar la definición del CRD en el clúster vacío
  validate_schema = false
  force_new       = true

  # CRÍTICO: Espera a que el Helm con índice correspondiente se instale
  depends_on = [
    helm_release.cert_manager
  ]
}