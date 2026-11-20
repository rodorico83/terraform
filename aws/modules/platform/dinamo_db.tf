# ==============================================================================
# TABLA DYNAMODB DE PRODUCCIÓN (CON PROVISIONED CAPACITY Y AUTO-SCALING)
# ==============================================================================

resource "aws_dynamodb_table" "production_table" {
  count        = var.enableDynamoDB ? 1 : 0
  name         = "${var.environment}-core-data-table"
  billing_mode = "PROVISIONED" # Estándar de producción para controlar costes y rendimiento

  # Capacidades base provisionadas para la tabla principal
  read_capacity  = 10
  write_capacity = 10

  hash_key  = "PK" # Partition Key (ej: USER#123)
  range_key = "SK" # Sort Key     (ej: PROFILE#METADATA)

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  # Atributo opcional utilizado en un GSI secundario
  attribute {
    name = "GSI1PK"
    type = "S"
  }

  attribute {
    name = "GSI1SK"
    type = "N"
  }

  # 1. Índice Secundario Global (GSI) optimizado para patrones de acceso alternativos
  global_secondary_index {
    name            = "GSI1"
    hash_key        = "GSI1PK"
    range_key       = "GSI1SK"
    projection_type = "ALL"
    read_capacity   = 5
    write_capacity  = 5
  }

  # 2. Recuperación ante desastres (Point-in-Time Recovery) - OBLIGATORIO en Prod
  point_in_time_recovery {
    enabled = true
  }

  # 3. Encriptación en reposo con KMS gestionado por AWS
  server_side_encryption {
    enabled = true
  }

  # 4. TTL para purgar datos efímeros automáticamente
  ttl {
    attribute_name = "TTL"
    enabled        = true
  }

  tags = merge(
    var.common_tags,
    {
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  )
}

# ==============================================================================
# AUTO-SCALING PARA LA TABLA PRINCIPAL (WCU / RCU)
# ==============================================================================

# Target Tracking para Capacidad de Escritura (WCU)
resource "aws_appautoscaling_target" "dynamodb_write_target" {
  count              = var.enableDynamoDB ? 1 : 0
  max_capacity       = 100
  min_capacity       = 10
  resource_id        = "table/${aws_dynamodb_table.production_table[0].name}"
  scalable_dimension = "dynamodb:table:WriteCapacityUnits"
  service_namespace  = "dynamodb"
}

resource "aws_appautoscaling_policy" "dynamodb_write_policy" {
  count              = var.enableDynamoDB ? 1 : 0
  name               = "DynamoDBWriteCapacityUtilization-${aws_dynamodb_table.production_table[0].name}"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.dynamodb_write_target[0].resource_id
  scalable_dimension = aws_appautoscaling_target.dynamodb_write_target[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.dynamodb_write_target[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "DynamoDBWriteCapacityUtilization"
    }
    target_value = 70.0 # Escala automáticamente si el consumo supera el 70% de la WCU asignada
  }
}

# Target Tracking para Capacidad de Lectura (RCU)
resource "aws_appautoscaling_target" "dynamodb_read_target" {
  count              = var.enableDynamoDB ? 1 : 0
  max_capacity       = 100
  min_capacity       = 10
  resource_id        = "table/${aws_dynamodb_table.production_table[0].name}"
  scalable_dimension = "dynamodb:table:ReadCapacityUnits"
  service_namespace  = "dynamodb"
}

resource "aws_appautoscaling_policy" "dynamodb_read_policy" {
  count              = var.enableDynamoDB ? 1 : 0
  name               = "DynamoDBReadCapacityUtilization-${aws_dynamodb_table.production_table[0].name}"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.dynamodb_read_target[0].resource_id
  scalable_dimension = aws_appautoscaling_target.dynamodb_read_target[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.dynamodb_read_target[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "DynamoDBReadCapacityUtilization"
    }
    target_value = 70.0 # Escala automáticamente si el consumo supera el 70% de la RCU asignada
  }
}