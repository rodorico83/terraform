output "vpc" {
  description = "Datos clave de la VPC agrupados en un solo objeto."
  value = {
    id                       = module.vpc.vpc_id
    cidr                     = module.vpc.vpc_cidr_block
    name                     = module.vpc.name
    public_subnet_ids        = module.vpc.public_subnets
    private_subnet_ids       = module.vpc.private_subnets
    database_subnet_ids      = module.vpc.database_subnets
    database_subnet_group_id = module.vpc.database_subnet_group_name
    private_route_table_ids  = module.vpc.private_route_table_ids
    on_prem_cidr             = var.on_prem_cidr
  }
}
