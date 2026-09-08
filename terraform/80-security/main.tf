# ============================================================
# LAYER 80 — SECURITY MONITORING
# CloudTrail + GuardDuty
#
# What this does:
#   CloudTrail  = records every action taken in the AWS account (CCTV)
#   GuardDuty   = watches for suspicious activity and alerts you (alarm system)
# ============================================================


# ── GUARDDUTY ──────────────────────────────────────────────
# Enabling GuardDuty is a single resource. AWS does the rest —
# it pulls VPC flow logs, DNS logs, and CloudTrail events automatically.

resource "aws_guardduty_detector" "main" {
  enable = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-guardduty"
  })
}

# Watch S3 buckets for suspicious access patterns
resource "aws_guardduty_detector_feature" "s3_logs" {
  detector_id = aws_guardduty_detector.main.id
  name        = "S3_DATA_EVENTS"
  status      = "ENABLED"
}

# Watch EKS audit logs for suspicious Kubernetes API calls
resource "aws_guardduty_detector_feature" "eks_audit_logs" {
  detector_id = aws_guardduty_detector.main.id
  name        = "EKS_AUDIT_LOGS"
  status      = "ENABLED"
}

# Scan EC2/EKS node disks for malware when a finding is triggered
resource "aws_guardduty_detector_feature" "malware_protection" {
  detector_id = aws_guardduty_detector.main.id
  name        = "EBS_MALWARE_PROTECTION"
  status      = "ENABLED"
}


# ── CLOUDTRAIL ─────────────────────────────────────────────
# CloudTrail writes logs to S3. We need to:
#   1. Create an S3 bucket to store the logs
#   2. Give CloudTrail permission to write to that bucket
#   3. Create the Trail itself

# S3 bucket to store CloudTrail logs
resource "aws_s3_bucket" "cloudtrail_logs" {
  # Bucket name must be globally unique — we include the account ID to ensure that
  bucket        = "${var.project_name}-${var.environment}-cloudtrail-${data.aws_caller_identity.current.account_id}"
  force_destroy = true  # lets Terraform delete the bucket (and its logs) on terraform destroy

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-cloudtrail-logs"
  })
}

# Block all public access to the log bucket — logs should never be public
resource "aws_s3_bucket_public_access_block" "cloudtrail_logs" {
  bucket                  = aws_s3_bucket.cloudtrail_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enable versioning — keeps old log files even if someone tries to delete them
resource "aws_s3_bucket_versioning" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Bucket policy — gives CloudTrail service permission to write log files here
resource "aws_s3_bucket_policy" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  # Must wait for public access block to be applied first
  depends_on = [aws_s3_bucket_public_access_block.cloudtrail_logs]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # CloudTrail checks the bucket ACL before writing
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail_logs.arn
        Condition = {
          StringEquals = {
            "aws:SourceArn" = "arn:aws:cloudtrail:${"us-east-1"}:${data.aws_caller_identity.current.account_id}:trail/${var.project_name}-${var.environment}-trail"
          }
        }
      },
      {
        # CloudTrail writes the actual log files here
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
            "aws:SourceArn" = "arn:aws:cloudtrail:${"us-east-1"}:${data.aws_caller_identity.current.account_id}:trail/${var.project_name}-${var.environment}-trail"
          }
        }
      }
    ]
  })
}

# The CloudTrail trail itself
resource "aws_cloudtrail" "main" {
  name           = "${var.project_name}-${var.environment}-trail"
  s3_bucket_name = aws_s3_bucket.cloudtrail_logs.id

  # Record events from ALL regions, not just us-east-1
  is_multi_region_trail = true

  # Include global services (IAM, STS, etc.) — important for security
  include_global_service_events = true

  # Detect if log files are tampered with after the fact
  enable_log_file_validation = true

  event_selector {
    # Record both read and write actions (not just destructive ones)
    read_write_type           = "All"
    include_management_events = true
  }

  depends_on = [aws_s3_bucket_policy.cloudtrail_logs]

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-trail"
  })
}


# ── OUTPUTS ────────────────────────────────────────────────
output "guardduty_detector_id" {
  description = "GuardDuty detector ID — use this to view findings in the AWS Console"
  value       = aws_guardduty_detector.main.id
}

output "cloudtrail_bucket" {
  description = "S3 bucket where CloudTrail logs are stored"
  value       = aws_s3_bucket.cloudtrail_logs.bucket
}

output "cloudtrail_arn" {
  description = "CloudTrail trail ARN"
  value       = aws_cloudtrail.main.arn
}
