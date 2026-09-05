provider "aws" {
  region = var.aws_region
}

# Proveedor 1: Para AWS EKS (Le ponemos un alias)
provider "kubernetes" {
  alias                  = "aws_eks" # <--- Apodo para el clúster de AWS
  host                   = aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.main.name]
  }
}

# Proveedor 2: Para su clúster Local On-Premises (Le ponemos otro alias)
provider "kubernetes" {
  alias                  = "on_premises"                # <--- Apodo para su oficina/data center
  host                   = "https://192.168.1.100:6443" # IP interna de su clúster local
  cluster_ca_certificate = file("${path.module}/certs/on_prem_ca.crt")
  token                  = var.on_prem_kubernetes_token # Token estático de su clúster local
}

# Proveedor Helm para conectar por dentro de su clúster EKS
provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.main.name]
      command     = "aws"
    }
  }
}