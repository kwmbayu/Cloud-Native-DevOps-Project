# Looks up the current AWS account ID automatically
# Used to build the CloudTrail S3 bucket name and policy
data "aws_caller_identity" "current" {}

# Looks up the current AWS region automatically
data "aws_region" "current" {}
