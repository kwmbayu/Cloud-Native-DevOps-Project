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

  # ── BACKUP & RECOVERY (Reliability Pillar) ─────────────────
  # Think of this like Time Machine on a Mac — automatic daily snapshots.
  # If data gets corrupted or deleted, you can restore to any point
  # within the last 7 days with a few clicks in the AWS console.

  # Automated daily backups kept for 7 days.
  # Window is a quiet period (3–4 AM UTC) when traffic is low.
  backup_retention_period = 7
  backup_window           = "03:00-04:00"

  # Maintenance window: OS patches applied weekly in a quiet window.
  maintenance_window = "Mon:04:00-Mon:05:00"

  # FINAL SNAPSHOT: When this RDS instance is destroyed (terraform destroy),
  # AWS takes one last complete backup BEFORE deleting anything.
  # Like hitting "Save" before closing a document forever.
  # Name format: expense-dev-final-<timestamp> (set at apply time)
  skip_final_snapshot              = false
  # The module uses _prefix — AWS appends a timestamp, producing:
  # expense-dev-final-20260908143022
  final_snapshot_identifier_prefix = "${var.project_name}-${var.environment}-final"

  # MULTI-AZ NOTE (prod recommendation):
  # multi_az = true  would run a live standby copy in a second AZ.
  # If the primary AZ fails, AWS fails over automatically in ~60 seconds.
  # Disabled here for dev to save cost (~doubles RDS price to ~$25/month).
  # Enable for any production or customer-facing environment.
  multi_az = false

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