# Amazon RDS PostgreSQL Database
resource "aws_db_instance" "postgres" {
  identifier            = "database"
  allocated_storage     = 20
  max_allocated_storage = 100
  engine                = var.db_config.engine
  engine_version        = var.db_config.engine_version
  instance_class        = var.db_config.instance_class
  port                  = var.db_config.port
  db_name               = var.db_config.database_name
  username              = var.db_config.admin_username

  manage_master_user_password = true

  db_subnet_group_name   = var.vpc.database_subnet_group_id
  vpc_security_group_ids = [aws_security_group.db.id]

  # Dynamic environment toggles
  multi_az                  = var.environment == "prod"
  deletion_protection       = var.environment == "prod"
  skip_final_snapshot       = var.environment != "prod"
  final_snapshot_identifier = var.environment == "prod" ? "database-final-snapshot-${var.environment}" : null
  backup_retention_period   = var.environment == "prod" ? 7 : 1

  tags = local.common_tags

  /*lifecycle {
    prevent_destroy = true
  }*/
}


# 2. El controlador de estado oficial de Terraform para RDS
resource "aws_rds_instance_state" "postgres_trigger" {
  # Apunta al identificador de tu recurso de base de datos actual
  identifier = aws_db_instance.postgres.identifier

  # Condicional dinámico: si la variable es true manda "available", si es false manda "stopped"
  state = var.db_config.enabled ? "available" : "stopped"
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


resource "aws_security_group_rule" "db_ingress" {
  for_each = {
    "eks_nodes"  = aws_security_group.eks_nodes.id
    "pod_app_sg" = aws_security_group.pod_app_sg.id
  }

  type                     = "ingress"
  from_port                = var.db_config.port
  to_port                  = var.db_config.port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.db.id
  source_security_group_id = each.value
  description              = "Allow PostgreSQL traffic from EKS resources"

}
