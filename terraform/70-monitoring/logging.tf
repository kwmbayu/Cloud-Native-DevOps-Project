# ============================================================
# CENTRALIZED LOGGING — CLOUDWATCH LOG GROUPS + IAM FOR FLUENT BIT
#
# What this does:
#   Creates the "filing cabinets" in CloudWatch where all pod logs land.
#   Creates an IAM role for Fluent Bit to write to those cabinets.
#
# Analogy:
#   Fluent Bit is a postal worker on every EKS node. It picks up
#   log files and delivers them here. This file:
#     a) Creates the mailboxes (CloudWatch Log Groups)
#     b) Issues the postal worker their ID badge (IAM role)
#
# Log Groups we create:
#   /expense/dev/application  — all pod logs from the expense namespace
#   /expense/dev/system       — Kubernetes system pod logs (kube-system)
#
# Fluent Bit will be deployed as a Kubernetes DaemonSet using the
#  manifests in k8s/fluent-bit/. Apply those after terraform apply.
# ============================================================


# ── CLOUDWATCH LOG GROUPS ────────────────────────────────────

# Application logs — the expense app's pod logs land here.
# Every time your Node.js app runs console.log(), it ends up here.
# Retention: 30 days (after 30 days old logs are deleted automatically — saves money)
resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "/expense/dev/application"
  retention_in_days = 30

  tags = merge(var.common_tags, {
    Name = "expense-dev-application-logs"
  })
}

# System logs — Kubernetes internal components (CoreDNS, kube-proxy, etc.)
# Useful for debugging networking and DNS issues.
# Shorter retention — these are less important than app logs.
resource "aws_cloudwatch_log_group" "system_logs" {
  name              = "/expense/dev/system"
  retention_in_days = 14

  tags = merge(var.common_tags, {
    Name = "expense-dev-system-logs"
  })
}


# ── DATA SOURCE: FETCH THE EKS CLUSTER DETAILS ──────────────
# Reads the live EKS cluster to find its OIDC issuer URL.
# The OIDC (OpenID Connect) issuer is like a "passport authority" for the cluster —
# it issues ID tokens that prove a Kubernetes service account is who it says it is.
# Without this, AWS has no way to trust the Fluent Bit service account.
#
# IMPORTANT: Apply 40-eks BEFORE applying 70-monitoring.
data "aws_eks_cluster" "expense" {
  name = "${var.project_name}-${var.environment}"
}

# Fetch the OIDC provider that was auto-created by the EKS module.
# The EKS terraform module (version ~> 20.0) creates this automatically.
data "aws_iam_openid_connect_provider" "eks" {
  url = data.aws_eks_cluster.expense.identity[0].oidc[0].issuer
}


# ── IAM POLICY — WHAT FLUENT BIT IS ALLOWED TO DO ──────────
# Principle of least privilege: Fluent Bit can ONLY write logs.
# It cannot read other AWS resources, delete anything, or change settings.
resource "aws_iam_policy" "fluent_bit_cloudwatch" {
  name        = "${var.project_name}-${var.environment}-fluent-bit-cloudwatch"
  description = "Allows Fluent Bit DaemonSet to ship logs to CloudWatch"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",    # Create a log group if one doesn't exist yet
          "logs:CreateLogStream",   # Create a log stream (one per pod)
          "logs:PutLogEvents",      # Write the actual log lines
          "logs:DescribeLogGroups",  # Check which log groups exist
          "logs:DescribeLogStreams"  # Check which log streams exist
        ]
        Resource = "arn:aws:logs:us-east-1:258464457244:log-group:/expense/dev/*"
      }
    ]
  })

  tags = var.common_tags
}


# ── IAM ROLE — FLUENT BIT'S IDENTITY BADGE (IRSA) ──────────
# IRSA = IAM Roles for Service Accounts.
# This is how Kubernetes pods get AWS permissions without hard-coding credentials.
#
# The analogy:
#   Normal IAM roles say "this EC2 server is allowed to do X."
#   IRSA says "this specific Kubernetes pod (identified by its service account) is allowed to do X."
#   It's like giving a door badge to a specific employee, not to everyone in the building.
#
# How it works:
#   1. Fluent Bit has a Kubernetes ServiceAccount called "fluent-bit" in the "logging" namespace
#   2. That ServiceAccount is annotated with the ARN of this IAM role
#   3. When Fluent Bit starts, Kubernetes injects a short-lived token
#   4. Fluent Bit presents that token to AWS STS to assume this role
#   5. AWS checks: "is this token from the EKS cluster I trust? YES. Give it the role."
resource "aws_iam_role" "fluent_bit" {
  name        = "${var.project_name}-${var.environment}-fluent-bit"
  description = "IAM role for Fluent Bit DaemonSet — allows writing logs to CloudWatch"

  # Trust policy: only the Fluent Bit service account can assume this role.
  # ${oidc_issuer_host}:sub = system:serviceaccount:logging:fluent-bit
  #   → "only the service account named fluent-bit in the logging namespace"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = data.aws_iam_openid_connect_provider.eks.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(data.aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:logging:fluent-bit"
            "${replace(data.aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "fluent_bit_cloudwatch" {
  role       = aws_iam_role.fluent_bit.name
  policy_arn = aws_iam_policy.fluent_bit_cloudwatch.arn
}


# ── STORE ROLE ARN IN SSM ────────────────────────────────────
# Save the Fluent Bit role ARN to SSM Parameter Store.
# This way the Fluent Bit service account YAML can read it without
# hard-coding an ARN. You'll paste this into the ServiceAccount annotation.
resource "aws_ssm_parameter" "fluent_bit_role_arn" {
  name        = "/${var.project_name}/${var.environment}/fluent_bit_role_arn"
  type        = "String"
  value       = aws_iam_role.fluent_bit.arn
  description = "IAM role ARN for Fluent Bit IRSA — annotate the Fluent Bit ServiceAccount with this"

  tags = var.common_tags
}


# ── OUTPUT — PRINT THE ROLE ARN ──────────────────────────────
# After terraform apply, this value is printed to the terminal.
# Copy it into k8s/fluent-bit/serviceaccount.yaml where it says FLUENT_BIT_ROLE_ARN.
output "fluent_bit_role_arn" {
  description = "Paste this ARN into k8s/fluent-bit/serviceaccount.yaml"
  value       = aws_iam_role.fluent_bit.arn
}
