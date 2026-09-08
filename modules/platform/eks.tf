# 1. IAM Role for EKS Control Plane
resource "aws_iam_role" "eks_cluster" {
  name = "eks-cluster-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "eks.amazonaws.com" } }]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.eks_cluster.name
}

# 2. EKS Control Plane
resource "aws_eks_cluster" "main" {
  name     = "${var.environment}-aws-cluster"
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = var.vpc.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = false
  }

  tags = local.common_tags

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller
  ]
}

# 3. IAM Role for EKS Worker Nodes
resource "aws_iam_role" "eks_nodes" {
  name = "eks-node-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  ])
  policy_arn = each.value
  role       = aws_iam_role.eks_nodes.name
}

# 4. EKS Node Group
resource "aws_eks_node_group" "private_nodes" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "private-workers"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = var.vpc.private_subnet_ids

  capacity_type  = var.eks.node_capacity_type
  instance_types = var.eks.node_instance_types

  scaling_config {
    desired_size = var.eks.desired_size
    max_size     = var.eks.max_size
    min_size     = var.eks.min_size
  }

  tags = local.common_tags

  depends_on = [aws_iam_role_policy_attachment.node_policies]
}

# 5. VPC CNI Addon (Supports Security Groups for Pods)
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"

  configuration_values = jsonencode({
    env = {
      ENABLE_POD_ENI = "true"
    }
  })

  tags = local.common_tags
}

# NOTE: the SecurityGroupPolicy that binds pods to a dedicated ENI security
# group lives in the software layer (modules/software/pod_sg_policy.tf).
# kubernetes_manifest needs API access at plan time, which is impossible in the
# same apply that creates the cluster.

# 6. Optional DevOps Access Entry
resource "aws_eks_access_entry" "devops_team" {
  count         = var.devops_role_arn != null ? 1 : 0
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.devops_role_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "devops_admin" {
  count         = var.devops_role_arn != null ? 1 : 0
  cluster_name  = aws_eks_cluster.main.name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = aws_eks_access_entry.devops_team[0].principal_arn

  access_scope {
    type = "cluster"
  }
}

# 2. Get the TLS certificate thumbprint of the EKS OIDC Issuer URL
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}
