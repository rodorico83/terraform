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

  lifecycle {
    prevent_destroy = true
  }
}
