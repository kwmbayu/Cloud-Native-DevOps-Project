# ============================================================
# KMS KEY — RDS ENCRYPTION
#
# What this does:
#   Creates a dedicated encryption key (padlock) for the RDS database.
#   All data written to the RDS disk is automatically encrypted with
#   this key. AWS manages the encryption/decryption transparently —
#   your app just reads and writes normally.
#
# Why a custom key instead of the default AWS-managed key?
#   - Full audit trail: you can see every time the key was used
#   - You can revoke access instantly by disabling the key
#   - Auto-rotation: AWS replaces the key material every year
#   - Cost: ~$1/month — minimal for the control you gain
# ============================================================

data "aws_caller_identity" "current" {}

resource "aws_kms_key" "rds" {
  description             = "KMS key for encrypting the ${var.project_name}-${var.environment} RDS database"
  deletion_window_in_days = 7      # wait 7 days before permanently deleting (safety net)
  enable_key_rotation     = true   # AWS rotates the key material every year automatically

  # Key policy: defines who can use and manage this key
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # The AWS account root has full control (required)
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        # RDS service is allowed to use this key to encrypt/decrypt data
        Sid    = "Allow RDS Service"
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-rds-kms"
  })
}

# Human-readable name for the key — visible in AWS Console as:
# AWS KMS → Customer managed keys → alias/expense-dev-rds
resource "aws_kms_alias" "rds" {
  name          = "alias/${var.project_name}-${var.environment}-rds"
  target_key_id = aws_kms_key.rds.key_id
}

# Store the KMS key ARN in SSM so other layers can reference it if needed
resource "aws_ssm_parameter" "rds_kms_key_arn" {
  name  = "/${var.project_name}/${var.environment}/rds_kms_key_arn"
  type  = "String"
  value = aws_kms_key.rds.arn

  tags = var.common_tags
}

output "rds_kms_key_arn" {
  description = "ARN of the KMS key used to encrypt the RDS database"
  value       = aws_kms_key.rds.arn
}

output "rds_kms_key_alias" {
  description = "Human-readable alias for the RDS KMS key"
  value       = aws_kms_alias.rds.name
}
