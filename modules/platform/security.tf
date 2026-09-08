# Security Group para los Nodos de EKS
resource "aws_security_group" "eks_nodes" {
  name        = "eks-nodes-sg"
  description = "Security group for EKS worker nodes"
  vpc_id      = var.vpc.vpc_id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.premises.on_prem_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.premises.on_prem_cidr]
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
#
# Deliberadamente sin bloques ingress/egress inline: las reglas se gestionan
# como recursos independientes, aqui y en la capa de software. Mezclar reglas
# inline con aws_security_group_rule hace que Terraform revoque en cada apply
# las reglas que no conoce.
resource "aws_security_group" "db" {
  name        = "db-sg"
  description = "Security group for RDS PostgreSQL database"
  vpc_id      = var.vpc.vpc_id

  tags = local.common_tags
}

resource "aws_security_group_rule" "db_from_eks_nodes" {
  type                     = "ingress"
  from_port                = var.db_config.port
  to_port                  = var.db_config.port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.db.id
  source_security_group_id = aws_security_group.eks_nodes.id
  description              = "Allow PostgreSQL traffic from EKS worker nodes"
}

# Security Group Exclusivo para Pods de la Aplicación (Pod ENI)
resource "aws_security_group" "pod_app_sg" {
  name        = "${var.environment}-pod-app-sg"
  description = "Security group applied directly to application pods via AWS VPC CNI"
  vpc_id      = var.vpc.vpc_id

  # ingress-nginx envia el trafico a la IP del pod y su containerPort, no al
  # puerto del Service, asi que este puerto debe ser el del contenedor.
  ingress {
    from_port       = var.app_container_port
    to_port         = var.app_container_port
    protocol        = "tcp"
    security_groups = [var.eks.node_security_group_id]
    description     = "ingress-nginx controller to application pods"
  }

  egress {
    from_port       = aws_db_instance.postgres.port
    to_port         = aws_db_instance.postgres.port
    protocol        = "tcp"
    security_groups = [aws_security_group.db.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.premises.on_prem_cidr]
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

  # STS, ECR, Secrets Manager, etc. Sin esto los pods con ENI dedicada no
  # pueden hablar con ningun endpoint de AWS.
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

resource "aws_security_group_rule" "db_from_pod_app_sg" {
  type                     = "ingress"
  from_port                = aws_db_instance.postgres.port
  to_port                  = aws_db_instance.postgres.port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.db.id #var.db.sg_group_db_id
  source_security_group_id = aws_security_group.pod_app_sg.id
  description              = "Allow PostgreSQL traffic from application pods"
}

