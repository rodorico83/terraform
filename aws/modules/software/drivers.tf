
/*
# Cómo funciona: Funciona a través de un driver de almacenamiento.
# Cuando tu Pod se enciende, el driver intercepta el arranque, va a AWS, descarga el secreto en caliente y lo monta directamente en la memoria RAM del contenedor como un archivo de texto virtual (tmpfs).
# Cómo lo lee tu App: Tu aplicación tiene que estar programada para leer el secreto desde un archivo de texto en una ruta del disco (ej: /mnt/secrets/db-password).
# Ventaja: El secreto nunca se escribe en el disco ni en el etcd de Kubernetes. Si alguien hackea la base de datos de Kubernetes, no encontrará ninguna contraseña

# 1. Kubernetes Secrets Store CSI Driver
resource "helm_release" "csi_secrets_store" {
  name       = "csi-secrets-store"
  repository = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
  chart      = "secrets-store-csi-driver"
  namespace  = "kube-system"

  set {
    name  = "syncSecret.enabled"
    value = "true"
  }
}

# 2. AWS Secrets Manager CSI Provider
resource "helm_release" "aws_secrets_provider" {
  name       = "secrets-provider-aws"
  repository = "https://aws.github.io/secrets-store-csi-driver-provider-aws"
  chart      = "secrets-store-csi-driver-provider-aws"
  namespace  = "kube-system"

  # ÚNICO PARÁMETRO OBLIGATORIO: Desactiva el sub-chart y acopla el plugin limpiamente
  set {
    name  = "secrets-store-csi-driver.install"
    value = "false"
  }

  # ─── EL TRUCO PARA EVITAR LA COLISIÓN DE PROPIEDAD ───
  # Le ordenamos al proveedor de AWS que no intente fabricar una ServiceAccount nueva,
  # sino que consuma la que ya existe en el sistema creada por el recurso de arriba.
  #set {
  #  name  = "serviceAccount.create"
  #  value = "false"
  #}

  #set {
  #  name  = "serviceAccount.name"
  #  value = "secrets-store-csi-driver"
  #}

  depends_on = [helm_release.csi_secrets_store]
}*/
