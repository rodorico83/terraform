# Amazon ECR Repository para el validador de base de datos
resource "aws_ecr_repository" "ecr_registry" {
  name                 = "aws-registry"
  image_tag_mutability = "IMMUTABLE" # Permite sobrescribir el tag 'latest' al hacer nuevos push
  image_scanning_configuration { scan_on_push = true }
  tags = local.common_tags
}

# Política de ciclo de vida para ECR (Mantiene solo las últimas 5 imágenes para ahorrar espacio)
resource "aws_ecr_lifecycle_policy" "ecr_registry_policy" {
  repository = aws_ecr_repository.ecr_registry.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Mantener solo las últimas 5 imágenes"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = { type = "expire" }
      }
    ]
  })
}