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

# ── ALERT EMAIL ─────────────────────────────────────────────
# The email address that receives all CloudWatch alarm notifications.
# Change this to your own email before applying.
variable "alert_email" {
  default     = "kwankoumbayu@gmail.com"
  description = "Email address to receive CloudWatch alarm notifications"
}
