# 1. IAM Role with trust policy for Argo CD service account
resource "aws_iam_role" "argocd_deployer" {
  name = "${var.environment}-argocd-deployer-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = { Federated = var.eks.oidc_provider_arn }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${var.eks.oidc_issuer}:sub" = "system:serviceaccount:argocd:argocd-application-controller"
            "${var.eks.oidc_issuer}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

# 2. Map the Argo CD Deployer AWS IAM Role to the Kubernetes group "argocd:business-operators" via EKS Access Entry
resource "aws_eks_access_entry" "argocd_deployer" {
  cluster_name  = var.eks.cluster_name
  principal_arn = aws_iam_role.argocd_deployer.arn
  type          = "STANDARD"
  kubernetes_groups = ["argocd:business-operators"]
}


/*# 3. Attach EKS Edit / Admin access policy to the access entry
resource "aws_eks_access_policy_association" "argocd_deployer_policy" {
  cluster_name  = var.eks.name
  principal_arn = aws_eks_access_entry.argocd_deployer.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy" # Or scoped custom policy
  access_scope {
    type = "cluster"
  }
}*/

# 3.1.  Define CLuster Role for ArgoCD
resource "kubernetes_cluster_role_v1" "argocd_business_operator" {
  #provider = kubernetes.aws_eks
  metadata { name = "${var.environment}-argocd-business-operator" }

  # Lectura global para detectar drift (Wiz no alerta por permisos de lectura)
  rule {
    api_groups = ["","*","vpcresources.k8s.aws"]
    resources  = ["*"]
    verbs      = ["get", "list", "watch"]
  }

  # Recursos necesarios para que funcionen tus aplicaciones de negocio
  rule {
    api_groups = ["", "apps", "networking.k8s.io", "batch", "autoscaling"]
    resources  = [
      "namespaces", "services", "endpoints", "pods",
      "deployments", "statefulsets", "daemonsets", "replicasets",
      "ingresses", "configmaps", "secrets", "persistentvolumeclaims",
      "horizontalpodautoscalers", "jobs", "cronjobs" , "podtemplates",
      "networkpolicies", "resourcequotas", "limitranges", "serviceaccounts",
      "pods/log" , "pods/portforward"
    ]
    verbs      = ["watch", "create", "update", "patch", "delete"]
  }

  # Permite que tu ejecución "tenant-baseline" inyecte Roles locales en los namespaces de las apps
  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["roles", "rolebindings"]
    verbs      = ["create", "update", "patch", "delete"]
    # ❌ Omitimos "clusterroles" para que Wiz no detecte riesgo de escalada de privilegios.
  }

  # Permisos para el plano de control de ArgoCD
  rule {
    api_groups = ["argoproj.io"]
    resources  = ["appprojects", "applications", "applicationsets", "rollouts", "analysistemplates"]
    verbs      = ["*"]
  }
  # Permisos para el external secrets CRDS
  rule {
    api_groups = ["external-secrets.io"]
    resources  = ["externalsecrets"]
    verbs      = ["*"]
  }
  # Permisos pare Istio CRDs
  rule {
    api_groups = ["networking.istio.io", "security.istio.io"]
    resources  = ["virtualservices", "destinationrules", "authorizationpolicies"]
    verbs      = ["*"]
  }

}

resource "kubernetes_cluster_role_binding_v1" "argocd_operator_binding" {
  metadata { name = "${var.environment}-argocd-operator-binding" }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.argocd_business_operator.metadata[0].name
  }

  # Mantiene la vinculación para accesos vía EKS Access Entry (IAM)
  subject {
    kind      = "Group"
    name      = "argocd:business-operators"
    api_group = "rbac.authorization.k8s.io"
  }

  # 🟢 VINCULA DIRECTAMENTE LA SERVICE ACCOUNT DE ARGOCD
  subject {
    kind      = "ServiceAccount"
    name      = "argocd-application-controller"
    namespace = "argocd"
  }
}

# 4. Zero-Trust Cluster Registration Secret (No static tokens!)
resource "kubernetes_secret" "argocd_cluster_aws" {
  #provider = kubernetes.aws_eks
  metadata {
    name      = "${var.environment}-aws-cluster"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
      "provider"                       = "aws"
      "environment"                    = var.environment
    }
  }

  data = {
    name   = "${var.environment}-aws-cluster"
    #server = var.eks.cluster_endpoint #via accessKey kubernetes group mappingg
    server = "https://kubernetes.default.svc" #via K8s serviceaccount
    config = jsonencode({
      # ------------------------------------------------------------------------
      # ZERO-TRUST IAM AUTHENTICATION (Replaces permanent bearerToken)
      # ------------------------------------------------------------------------
      awsAuthConfig = {
        clusterName = var.eks.cluster_name
        roleARN     = aws_iam_role.argocd_deployer.arn
      }
      tlsClientConfig = {
        insecure = false
        caData   = base64encode(var.eks.ca_certificate)
      }
    })
  }

  depends_on = [helm_release.argocd]
}

# 5. Argo CD Helm Chart
resource "helm_release" "argocd" {
  count            = 1 #(var.enable_argocd && var.environment == "prod") ? 1 : 0
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.7.0"
  namespace        = "argocd"
  create_namespace = true

  values = [
    yamlencode({

      global = { nodeSelector = { "karpenter.sh/nodepool" = "low-cost-pool-infra" } }

      # 1. CONTROLADOR PRINCIPAL (Elección de Líder automática)
      controller = {
        replicas = 1
        clusterAdminAccessEnabled = false # Not create the full permissions Rol binding
        serviceAccount = {
          create = true
          annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.argocd_deployer.arn }
        }
        metrics = {
          enabled = true
          serviceMonitor = {
            enabled = true
            # Asegura que Prometheus busque el ServiceMonitor sin restricciones de Namespace
            additionalLabels = { release = "kube-prometheus-stack" }
          }
        }
        # Límites estrictos para que no consuma de más en tus instancias Spot
        resources = {
          requests = { cpu = "100m", memory = "400Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
        /* # Required in when using cluster endpoint instead of FQDN
        env = [
          {
            name  = "AWS_STS_REGIONAL_ENDPOINTS"
            value = "regional"
          },
          {
            name  = "AWS_REGION"
            value = "eu-south-2"
          }
        ]*/
      }

      # 2. EL SERVIDOR DE REPOSITORIOS (Stateless - Conexión a tu GitHub privado)
      repoServer = {
        autoscaling = {
          enabled = false # ──► DESACTIVAMOS EL HPA PARA INFRAESTRUCTURA BASE 🛑
        }
        replicas = 1 # Fijamos 2 réplicas estáticas en Alta Disponibilidad
        metrics = {
          enabled = true
          serviceMonitor = {
            enabled = true
            additionalLabels = { release = "kube-prometheus-stack" }
          }
        }
        resources = {
          requests = { cpu = "100m", memory = "128Mi" }
          limits   = { cpu = "500m", memory = "256Mi" }
        }
      }

      # 3. APPLICATIONSET CONTROLLER
      applicationset = {
        priorityClassName = "system-cluster-critical"
        resources = {
          requests = {
            cpu    = "25m"
            memory = "64Mi"
          }
          limits = {
            cpu    = "100m"
            memory = "128Mi"
          }
        }
        metrics = {
          enabled = true
          serviceMonitor = {
            enabled = true
            additionalLabels = { release = "kube-prometheus-stack" }
          }
        }
      }

      # 3. LA API / PANEL WEB DE ARGOCD (Stateless - Activo-Activo)
      server = {
        extraArgs =  [ "--insecure" ] # Desactiva TLS interno del container para que acepte HTTP puro desde NGINX

        # 🎯 1. INIT CONTAINER OFICIAL PARA INSTALAR LA EXTENSIÓN
        initContainers = [
          {
            name  = "argo-rollouts-extension"
            image = "quay.io/argoprojlabs/argocd-extension-installer:v0.0.8"
            env = [
              {
                name  = "EXTENSION_URL"
                value = "https://github.com/argoproj-labs/rollout-extension/releases/download/v0.3.5/extension.tar"
              }
            ]
            volumeMounts = [
              {
                name      = "extensions"
                mountPath = "/tmp/extensions/"
              }
            ]
            /*securityContext = {
              runAsUser = 1000
              allowPrivilegeEscalation = false
            }*/
          }
        ]

        # 🎯 2. MONTAJE DEL VOLUMEN EN EL CONTENEDOR 'server'
        volumeMounts = [
          {
            name      = "extensions"
            mountPath = "/tmp/extensions/"
          }
        ]

        # 🎯 3. DECLARACIÓN DEL VOLUMEN EN MEMORIA COMPARTIDO
        volumes = [
          {
            name     = "extensions"
            emptyDir = {}
          }
        ]

        autoscaling = { enabled = false }
        replicas = 1 # 2 Pods atendiendo peticiones web en paralelo
        priorityClassName = "system-cluster-critical"

        # ACTIVACIÓN DEL INGRESS DENTRO DEL HELM CHART
        ingress = {
          enabled   = true
          ingressClassName = "nginx" # Vincula este Ingress al controlador Nginx

          # Enrutamiento por subdominio
          hostname = "argocd.aws.rj-engineering.com"
          annotations = {
            # Anotaciones críticas para que Nginx no rompa la redirección SSL interna de Argo
            "cert-manager.io/cluster-issuer"               = "letsencrypt-${var.environment}"
            "nginx.ingress.kubernetes.io/backend-protocol" = "HTTP"
            "nginx.ingress.kubernetes.io/ssl-redirect"     = "true"
          }

          # Bloque TLS obligatorio para que Cert-Manager guarde el certificado seguro
          tls = [
            {
              hosts      = ["argocd.aws.rj-engineering.com"]
              secretName = "argocd-server-tls"
            }
          ]

        }
        resources = {
          requests = { cpu = "100m", memory = "64Mi" }
          limits   = { cpu = "250m", memory = "256Mi" }
        }
      }

      # 4. EL CLÚSTER DE CACHÉ DE REDIS (Sentinel HA)
      # Activa automáticamente 3 réplicas coordinadas de Redis (1 maestro + 2 copias de respaldo)
      redis-ha = {
        enabled = false
        resources = {
          requests = { cpu = "50m", memory = "64Mi" }
          limits   = { cpu = "200m", memory = "128Mi" }
        }
      }

      notifications = {
        enabled = true
        replicas = 1
        resources = {
          requests = { cpu = "50m", memory = "64Mi" }
          limits   = { cpu = "100m", memory = "128Mi" }
        }
      }

    })
  ]
  depends_on = [helm_release.kube_prometheus_stack,helm_release.cert_manager, kubectl_manifest.karpenter_node_pool_infra]
}

# 6. Desplegamos el Root App de forma asíncrona y segura al final
resource "kubectl_manifest" "argocd_root_bootstrap" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "root-bootstrap"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = "https://github.com/rodorico83/gitops-manifests"
        targetRevision = "master"
        path           = "bootstrap"
      }
      destination = {
        server    = "https://kubernetes.default.svc" # O puedes usar var.eks.cluster_endpoint
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
      }
    }
  })

  validate_schema = false # No rompe el plan si el CRD no se ha creado aún
  force_new       = true
  depends_on      = [helm_release.argocd]
}


# 7. Secret para autenticar Argo CD contra tu repositorio privado de GitHub
resource "kubernetes_secret" "argocd_repo_gitops_manifests" {
  #provider = kubernetes.aws_eks
  metadata {
    name      = "repo-gitops-manifests"
    namespace = "argocd"
    # 🎯 ETIQUETA OBLIGATORIA: Indica a Argo CD que esto es un repositorio registrado
    labels = { "argocd.argoproj.io/secret-type" = "repository" }
  }

  data = {
    type     = "git"
    url      = "https://github.com/rodorico83/gitops-manifests"
    username = "rodorico83"
    password = var.github.read_token # Personal Access Token (PAT) con permisos de lectura (repo scope)
  }
  depends_on = [helm_release.argocd]
}


# 8. Crear el namespace dedicado para Argo Rollouts
resource "kubernetes_namespace" "argo_rollouts" {
  metadata {
    name = "argo-rollouts"
    labels = { "app.kubernetes.io/managed-by" = "terraform" }
  }
}

# 8. Desplegar el Helm Chart de Argo Rollouts
resource "helm_release" "argo_rollouts" {
  name       = "argo-rollouts"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-rollouts"
  version    = "2.35.0" # Ajusta a la versión del Chart que necesites

  namespace        = kubernetes_namespace.argo_rollouts.metadata[0].name
  create_namespace = false

  values = [
    yamlencode({
      dashboard = { enabled = false }
      controller = {
        replicas = 1
        priorityClassName = "system-cluster-critical"
        resources = {
          requests = {
            cpu    = "25m"
            memory = "64Mi"
          }
          limits = {
            cpu    = "100m"
            memory = "128Mi"
          }
        }
        metrics = {
          enabled = true
          serviceMonitor = {
            enabled = true
            additionalLabels = { release = "kube-prometheus-stack" }
          }
        }
      }
      argocdServer = { enabled = true }
    })
  ]
  # Asegura que el namespace existe antes de instalar
  depends_on = [kubernetes_namespace.argo_rollouts]
}

/*
# Static cluster bearer Token approach replaced by IAM / OIDC (IRSA + EKS Access Entries)
# 1. Crear la ServiceAccount en kube-system
resource "kubernetes_service_account_v1" "argocd_manager" {
  metadata {
    name      = "argocd-manager"
    namespace = "kube-system"
  }

  depends_on = [helm_release.argocd]
}

# 2. Asignar permisos de Cluster-Admin a la ServiceAccount
resource "kubernetes_cluster_role_binding_v1" "argocd_manager" {
  metadata {
    name = "argocd-manager-binding"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.argocd_manager.metadata[0].name
    namespace = kubernetes_service_account_v1.argocd_manager.metadata[0].namespace
  }
  depends_on = [kubernetes_service_account_v1.argocd_manager]
}

#  3. Vincular Secret a la Service Account
resource "kubernetes_secret_v1" "argocd_manager_token" {
  metadata {
    name      = "argocd-manager-token"
    namespace = "kube-system"
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.argocd_manager.metadata[0].name
    }
  }

  type = "kubernetes.io/service-account-token"

  depends_on = [kubernetes_service_account_v1.argocd_manager]
}

# Secret para registrar el clúster AWS en Argo CD con sus etiquetas
resource "kubernetes_secret" "argocd_cluster_aws" {
  metadata {
    name      = "${var.environment}-aws-cluster"
    namespace = "argocd"

    # 🎯 ETIQUETAS QUE BUSCA EL APPLICATIONSET
    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
      "provider"                       = "aws"
      "environment"                    = var.environment
    }
  }

  data = {
    name   = "${var.environment}-aws-cluster"
    server = var.eks.cluster_endpoint
    config = jsonencode({
      bearerToken = kubernetes_secret_v1.argocd_manager_token.data["token"]
      tlsClientConfig = {
        insecure = false
        caData   = base64encode(var.eks.ca_certificate)
      }
    })
  }

  depends_on = [helm_release.argocd, kubernetes_secret_v1.argocd_manager_token ]
}
*/