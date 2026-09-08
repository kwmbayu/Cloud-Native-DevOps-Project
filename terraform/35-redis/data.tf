# ============================================================
# DATA SOURCES — reads outputs from earlier Terraform layers
#
# Apply order: 00-vpc → 10-sg → 35-redis
# ============================================================

# VPC ID — needed to create the Redis security group
data "aws_ssm_parameter" "vpc_id" {
  name = "/${var.project_name}/${var.environment}/vpc_id"
}

# Private subnet IDs — Redis lives in private subnets (no public internet access).
# The same subnets where EKS nodes live, so they can reach Redis without NAT.
data "aws_ssm_parameter" "private_subnet_ids" {
  name = "/${var.project_name}/${var.environment}/private_subnet_ids"
}

# EKS node security group ID — we allow Redis traffic ONLY from EKS nodes.
# No other machine in the VPC (bastion, VPN) can reach Redis.
# Principle of least privilege: the cache is only accessible by the app.
data "aws_ssm_parameter" "node_sg_id" {
  name = "/${var.project_name}/${var.environment}/node_sg_id"
}

# SNS alerts topic — for CloudWatch alarms (high memory, evictions)
data "aws_ssm_parameter" "sns_alerts_arn" {
  name = "/${var.project_name}/${var.environment}/sns_alerts_arn"
}
