
# Principales Parámetros que se Configuran en Producción
#   Alta Disponibilidad (Multi-AZ): Duplica la instancia de forma síncrona en otra zona de disponibilidad para garantizar conmutación por error (failover) automática ante caídas de hardware.
#   Clase de Instancia (instance_class) y Almacenamiento (allocated_storage / max_allocated_storage): Dimensionar los recursos de CPU/RAM y permitir el autoincremento de disco (Storage Autoscaling) para evitar cortes por falta de espacio.
#   Retención de Copias de Seguridad y Snapshots (backup_retention_period y deletion_protection): Mantener un histórico de backups (por ejemplo, de 7 a 35 días) y proteger la base de datos contra borrados accidentales mediante API o consola.
#   Parámetros del Motor (aws_db_parameter_group): Ajustar configuraciones internas de PostgreSQL como max_connections (para evitar saturación de conexiones desde los microservicios en EKS), shared_buffers, work_mem y la activación de logs de consultas lentas (log_min_duration_statement).
#   Cifrado en Reposo (storage_encrypted) y Contraseñas Automatizadas: Uso de claves KMS gestionadas y rotación de credenciales con AWS Secrets Manager.

# Parameter Group personalizado para producción (Ajustes de motor PostgreSQL)
/*resource "aws_db_parameter_group" "postgres_prod_params" {
  name   = "database-postgres-prod-params-${var.environment}"
  family = "postgres15" # Ajusta según la versión de tu engine_version (ej. postgres15, postgres16)

  parameter {
    name  = "max_connections"
    value = "200" # Ajustado según la concurrencia esperada de los pods en EKS
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000" # Registra en CloudWatch las consultas que tarden más de 1000ms (1s) para auditoría/optimización
  }

  parameter {
    name  = "shared_buffers"
    value = "{DBInstanceClassMemory/4}" # Configuración recomendada: ~25% de la RAM de la instancia
    #apply_method = "pending-reboot"
  }

  tags = local.common_tags
}*/

# Amazon RDS PostgreSQL Database
resource "aws_db_instance" "postgres" {
  identifier            = "database"
  allocated_storage     = 5
  max_allocated_storage = 10
  engine                = var.db_config.engine
  engine_version        = var.db_config.engine_version
  instance_class        = var.db_config.instance_class   # Ideally "db.m6i.large"
  port                  = var.db_config.port
  db_name               = var.db_config.database_name
  username              = var.db_config.admin_username

  manage_master_user_password = true
  storage_encrypted           = true
  auto_minor_version_upgrade  = true

  db_subnet_group_name   = var.vpc.database_subnet_group_id
  vpc_security_group_ids = [aws_security_group.db.id]

  # Asociación del Parameter Group optimizado
  #parameter_group_name = aws_db_parameter_group.postgres_prod_params.name

  # Dynamic environment toggles
  multi_az                  = var.environment == "prod"
  publicly_accessible       = false
  deletion_protection       = false
  #deletion_protection       = var.environment == "prod" # Protects deletion via API (UI/CLI/SDK)
  skip_final_snapshot       = true
  #skip_final_snapshot       = var.environment != "prod"
  final_snapshot_identifier = var.environment == "prod" ? "database-final-snapshot-${var.environment}" : null
  backup_retention_period   = var.environment == "prod" ? 7 : 1 # 30 dias historico backup para produccion
  backup_window             = "03:00-04:00"              # Ventana horaria de copias de seguridad (UTC)
  maintenance_window        = "Sun:04:30-Sun:05:30"      # Ventana controlada para parches de AWS

  tags = local.common_tags
  # Prevent destruction via terraform apply (check during terraform so there is not even API call)
  lifecycle { prevent_destroy = false }
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

/*

# Password rotation 20 days
# 1. Obtener los datos del secreto creado automáticamente por RDS
data "aws_secretsmanager_secret" "rds_master_secret" {
  arn = aws_db_instance.postgres.master_user_secret[0].secret_arn
}

# 2. Desplegar la función Lambda oficial de AWS para rotación de PostgreSQL
# (Utilizamos el Serverless Application Repository de AWS)
resource "aws_serverlessapplicationrepository_cloudformation_stack" "postgres_rotation_single_user" {
  name           = "rds-postgres-rotation-stack"
  application_id = "arn:aws:serverlessrepo:eu-south-2:555968473487:applications/SecretsManagerRDSPostgreSQLRotationSingleUser"
  capabilities   = ["CAPABILITY_IAM", "CAPABILITY_RESOURCE_POLICY"]

  parameters = {
    functionName = "rds-postgres-master-rotation-lambda"
    vpcSubnetIds = join(",", var.vpc.private_subnet_ids)
    vpcSecurityGroupIds = aws_security_group.db.id
  }
}

# 3. Configurar la regla de rotación automática en Secrets Manager
resource "aws_secretsmanager_secret_rotation" "rds_master_rotation" {
  secret_id           = data.aws_secretsmanager_secret.rds_master_secret.id
  rotation_lambda_arn = aws_serverlessapplicationrepository_cloudformation_stack.postgres_rotation_single_user.outputs.RotationLambdaARN

  rotation_rules {
    automatically_after_days = 30 # Intervalo de rotación en días
  }
}
*/