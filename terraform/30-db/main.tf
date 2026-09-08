module "db" {
  source = "terraform-aws-modules/rds/aws"
  identifier = "${var.project_name}-${var.environment}" #expense-dev

  engine            = "mysql"
  engine_version    = "8.0"
  instance_class    = "db.t3.micro"
  allocated_storage = 5

  db_name  = "transactions" #default schema for expense project
  username = "root"
  port     = "3306"

  vpc_security_group_ids = [data.aws_ssm_parameter.db_sg_id.value]  

  # DB subnet group
  db_subnet_group_name = data.aws_ssm_parameter.db_subnet_group_name.value

  # DB parameter group
  family = "mysql8.0"

  # DB option group
  major_engine_version = "8.0"

  tags = merge(
    var.common_tags,
    {
        Name = "${var.project_name}-${var.environment}"
    }
  )

  manage_master_user_password = false
  # password_wo = write-only: Terraform accepts the value but NEVER stores it
  # in the state file or prints it in plan output. Safer than plain `password`.
  # Run: terraform apply -var="db_password=YourPassword"
  # Or set environment variable: export TF_VAR_db_password="YourPassword"
  password_wo         = var.db_password
  password_wo_version = 1   # increment this number to trigger a password rotation
  skip_final_snapshot = true

  # ── ENCRYPTION AT REST ──────────────────────────────────
  # All data on the RDS disk is encrypted with AES-256.
  # Encryption can ONLY be enabled at creation time — not on a running instance.
  # The KMS key is defined in kms.tf (custom key with rotation + audit trail).
  storage_encrypted = true
  kms_key_id        = aws_kms_key.rds.arn

  parameters = [
    {
      name  = "character_set_client"
      value = "utf8mb4"
    },
    {
      name  = "character_set_server"
      value = "utf8mb4"
    }
  ]

  options = [
    {
      option_name = "MARIADB_AUDIT_PLUGIN"

      option_settings = [
        {
          name  = "SERVER_AUDIT_EVENTS"
          value = "CONNECT"
        },
        {
          name  = "SERVER_AUDIT_FILE_ROTATIONS"
          value = "37"
        },
      ]
    },
  ]
 
}

# Route53 record removed -- no domain configured
# Connect to RDS using the endpoint address directly