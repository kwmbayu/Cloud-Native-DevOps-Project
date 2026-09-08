variable "project_name" {
  default = "expense"
}

variable "environment" {
  default = "dev"
}

variable "common_tags" {
  default = {
    Project = "expense"
    Environment = "dev"
    Terraform = "true"
  }
}

# DB password — sensitive so Terraform never prints it in logs
# Set via: terraform apply -var="db_password=YourPassword"
# Or:      export TF_VAR_db_password="YourPassword"
variable "db_password" {
  description = "MySQL root password for RDS — stored in Secrets Manager (85-secrets layer)"
  type        = string
  sensitive   = true
}
