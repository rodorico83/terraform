# 1. Guardar la contraseña de forma segura en AWS EKS
resource "kubernetes_secret" "db_credentials_aws" {
  provider = kubernetes.aws_eks # Destino: AWS

  metadata {
    name      = "database-credentials"
    namespace = "default"
  }

  # Los datos dentro de un kubernetes_secret se codifican automáticamente
  data = {
    username = aws_db_instance.postgres.username
    password = random_password.db_password.result # <--- Inyección directa y secreta
  }

  depends_on = [aws_eks_node_group.private_nodes]
}

# 2. Guardar la contraseña de forma segura en su clúster LOCAL (On-Premises)
resource "kubernetes_secret" "db_credentials_local" {
  provider = kubernetes.on_premises # Destino: Su oficina/Data Center

  metadata {
    name      = "database-credentials"
    namespace = "default"
  }

  data = {
    username = aws_db_instance.postgres.username
    password = random_password.db_password.result
  }
}