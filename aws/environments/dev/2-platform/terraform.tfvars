aws_region          = "eu-south-2"
environment         = "dev"
node_instance_types = [ "t3.medium", "t3.small" ]
db_enabled = false
node_capacity_type  = "SPOT" #"ON_DEMAND"
node_group_size = {
  desired = 1
  min = 1
  max = 2
}

