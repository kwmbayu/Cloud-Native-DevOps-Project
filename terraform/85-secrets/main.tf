# ============================================================
# LAYER 85 — SECRETS MANAGER
#
# What this does:
#   Stores database credentials in a secure vault (AWS Secrets Manager)
#   instead of having them hardcoded in Terraform files or app config.
#
#   Think of it like a bank vault for passwords:
#     - Your app asks the vault for the password at runtime
#     - Nobody sees the actual password in the code
#     - You can rotate (change) the password without redeploying anything
#
# APPLY ORDER: This layer can be applied independently.
#   Once 30-db is applied and you have the RDS endpoint,
#   update the host field below and re-run: terraform apply
# ============================================================


# ── THE VAULT BOX ──────────────────────────────────────────
# Creates the vault itself (just the named container)
resource "aws_secretsmanager_secret" "db_credentials" {
  name        = "${var.project_name}/${var.environment}/db-credentials"
  description = "MySQL credentials for the ${var.project_name}-${var.environment} RDS instance"

  # How long AWS keeps a deleted secret before permanently destroying it.
  # 0 = delete immediately (good for dev/test; use 7-30 days in prod)
  recovery_window_in_days = 0

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-db-credentials"
  })
}

# ── THE CONTENTS ───────────────────────────────────────────
# Stores the actual credentials inside the vault as JSON.
# After 30-db is applied, replace the host placeholder with the real RDS endpoint.
resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id

  # JSON format — the application decodes this to get individual fields:
  #   import json, boto3
  #   secret = json.loads(boto3.client('secretsmanager').get_secret_value(SecretId='expense/dev/db-credentials')['SecretString'])
  #   db_password = secret['password']
  secret_string = jsonencode({
    username = "root"
    password = var.db_password
    host     = var.db_host        # placeholder; update after 30-db apply
    port     = "3306"
    dbname   = "transactions"
    engine   = "mysql"
  })
}


# ── IAM POLICY — THE PERMISSION SLIP ───────────────────────
# Any role attached to this policy can open the DB credentials vault.
# Attach it to the EKS node role so application pods can read the password.
resource "aws_iam_policy" "read_db_secret" {
  name        = "${var.project_name}-${var.environment}-read-db-secret"
  description = "Allows reading the DB credentials secret from Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowReadDBSecret"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue", # Read the actual password
          "secretsmanager:DescribeSecret", # Read metadata (name, rotation status)
        ]
        Resource = aws_secretsmanager_secret.db_credentials.arn
      },
      {
        # KMS permission for decryption — needed if you ever use a custom KMS key
        Sid    = "AllowKMSDecrypt"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.us-east-1.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = var.common_tags
}

# ── SSM PARAMETERS — SHARE THE ADDRESSES ───────────────────
# Store the secret ARN and policy ARN in SSM Parameter Store so
# other Terraform layers can look them up without hardcoding.
# The ARN is like the vault's address — safe to share, not the password itself.
resource "aws_ssm_parameter" "db_secret_arn" {
  name  = "/${var.project_name}/${var.environment}/db_secret_arn"
  type  = "String"
  value = aws_secretsmanager_secret.db_credentials.arn

  tags = var.common_tags
}

resource "aws_ssm_parameter" "read_db_secret_policy_arn" {
  name  = "/${var.project_name}/${var.environment}/read_db_secret_policy_arn"
  type  = "String"
  value = aws_iam_policy.read_db_secret.arn

  tags = var.common_tags
}


# ── OUTPUTS ────────────────────────────────────────────────
output "db_secret_arn" {
  description = "ARN of the DB credentials secret — use in app config to fetch the password"
  value       = aws_secretsmanager_secret.db_credentials.arn
}

output "db_secret_name" {
  description = "Name of the secret in Secrets Manager (visible in AWS Console)"
  value       = aws_secretsmanager_secret.db_credentials.name
}

output "read_db_secret_policy_arn" {
  description = "IAM policy ARN — attach to any role that needs to read DB credentials"
  value       = aws_iam_policy.read_db_secret.arn
}
