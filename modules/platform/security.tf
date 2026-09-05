# Security Group para los Nodos de EKS
resource "aws_security_group" "eks_nodes" {
  name        = "eks-nodes-sg"
  description = "Security group for EKS worker nodes"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.on_prem_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.on_prem_cidr]
  }

  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

# Security Group para Amazon RDS PostgreSQL
resource "aws_security_group" "db" {
  name        = "db-sg"
  description = "Security group for RDS PostgreSQL database"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = var.db_config.port
    to_port         = var.db_config.port
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_nodes.id]
  }

  tags = local.common_tags
}

# Security Group Exclusivo para Pods de la Aplicación (Pod ENI)
resource "aws_security_group" "pod_app_sg" {
  name        = "pod-app-sg"
  description = "Security group applied directly to application pods via AWS VPC CNI"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.alb_security_group_id == null ? [] : [var.alb_security_group_id]
    content {
      from_port       = 80
      to_port         = 80
      protocol        = "tcp"
      security_groups = [ingress.value]
    }
  }

  egress {
    from_port       = var.db_config.port
    to_port         = var.db_config.port
    protocol        = "tcp"
    security_groups = [aws_security_group.db.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.on_prem_cidr]
  }

  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

resource "aws_security_group_rule" "db_from_pod_app_sg" {
  type                     = "ingress"
  from_port                = var.db_config.port
  to_port                  = var.db_config.port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.db.id
  source_security_group_id = aws_security_group.pod_app_sg.id
  description              = "Allow PostgreSQL traffic from application pods"
}
