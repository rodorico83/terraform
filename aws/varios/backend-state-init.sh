aws_region="eu-west-1"

aws s3api create-bucket \
    --bucket example-tfstate-storage-2026 \
    --region ${aws_region} --create-bucket-configuration LocationConstraint=eu-west-1
	
aws s3api put-bucket-versioning \
    --bucket example-tfstate-storage-2026 \
    --versioning-configuration Status=Enabled
	

## DinamoDB table not required anymore since Terraform v1.11+
exit 0

aws dynamodb create-table \
    --table-name terraform-state-lock \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region ${aws_region}	
	
	
aws dynamodb delete-table --table-name terraform-state-lock --region ${aws_region}