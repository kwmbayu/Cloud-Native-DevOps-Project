variable "project_name" {
  default = "expense"
}

variable "environment" {
  default = "dev"
}

variable "common_tags" {
  default = {
    Project     = "expense"
    Environment = "dev"
    Terraform   = "true"
  }
}

# The DB password — marked sensitive so Terraform NEVER prints it in logs or plan output
# Override at apply time: terraform apply -var="db_password=NewStrongPass1!"
variable "db_password" {
  description = "MySQL root password for the expense RDS instance"
  type        = string
  sensitive   = true
  default     = "ExpenseApp1"
}

# The RDS endpoint — placeholder until 30-db layer is applied
# After 30-db apply, get the endpoint from:
#   aws rds describe-db-instances --region us-east-1 --query "DBInstances[0].Endpoint.Address"
# Then: terraform apply -var="db_host=expense-dev.xxxxxxxxx.us-east-1.rds.amazonaws.com"
variable "db_host" {
  description = "RDS endpoint hostname — set after 30-db layer is applied"
  type        = string
  default     = "PLACEHOLDER_update_after_30_db_apply"
}
