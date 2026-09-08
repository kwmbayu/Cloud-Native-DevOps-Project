# Get the current AWS account ID (used for IAM policy ARNs)
data "aws_caller_identity" "current" {}

# NOTE: The RDS endpoint SSM parameter is written by the 30-db layer after terraform apply.
# Since 30-db has not been applied yet, we don't look it up here.
# Once you apply 30-db, you can update the secret's host field by running:
#   terraform apply -var="db_password=YourPassword"
# from this directory — it will re-read the endpoint and update the secret.
