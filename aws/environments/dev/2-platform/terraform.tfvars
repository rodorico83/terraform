aws_region          = "eu-south-2"
environment         = "dev"
node_instance_types = [ "t3.medium" ]
db_enabled = "true"
node_capacity_type  = "SPOT" #"ON_DEMAND"
node_group_size = {
  desired = 2
  min = 1
  max = 4
}

