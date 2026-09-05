variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "environment" {
  type    = string
  default = "dev"
}

# Fetch Platform Layer state for Dev
data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = "example-tfstate-storage-2026"
    key    = "dev/platform/terraform.tfstate"
    region = var.aws_region
  }
}

module "software" {
  source = "../../../modules/software"

  environment          = var.environment
  enable_argocd        = true
  enable_reloader      = true
  enable_ingress_nginx = true
  enable_cert_manager  = true
}
