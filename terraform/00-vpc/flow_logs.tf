# ============================================================
# VPC FLOW LOGS
#
# What this does:
#   Records ALL network traffic in and out of the VPC.
#   Think of it as security cameras at every door in your building.
#
#   Each log entry records:
#     - Source IP & port
#     - Destination IP & port
#     - Protocol (TCP/UDP)
#     - Bytes transferred
#     - Whether the packet was ACCEPTED or REJECTED
#
#   Rejected connections are especially valuable — they show
#   attempted intrusions caught by security groups.
# ============================================================


# ── CLOUDWATCH LOG GROUP ────────────────────────────────────
# This is the "filing cabinet" where all flow log records are stored.
# Retention = 30 days (keeps costs low; increase to 90 days for compliance)
resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/${var.project_name}/${var.environment}/vpc-flow-logs"
  retention_in_days = 30

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-vpc-flow-logs"
  })
}


# ── IAM ROLE — VPC'S PERMISSION TO WRITE LOGS ──────────────
# VPC Flow Logs is an AWS service, and like any AWS service,
# it needs an IAM role to act on your behalf.
# This role says: "the VPC Flow Logs service is allowed to write to CloudWatch"
resource "aws_iam_role" "vpc_flow_logs" {
  name = "${var.project_name}-${var.environment}-vpc-flow-logs-role"

  # Trust policy: only the VPC flow logs service can assume this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.common_tags
}

# ── IAM POLICY — WHAT THE ROLE IS ALLOWED TO DO ────────────
# Principle of least privilege: the role can ONLY write flow logs.
# It cannot read other logs, modify anything, or delete anything.
resource "aws_iam_role_policy" "vpc_flow_logs" {
  name   = "${var.project_name}-${var.environment}-vpc-flow-logs-policy"
  role   = aws_iam_role.vpc_flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",       # Create the log group if it doesn't exist
          "logs:CreateLogStream",      # Create a new log stream (daily partition)
          "logs:PutLogEvents",         # Write the actual log entries
          "logs:DescribeLogGroups",    # Read log group metadata
          "logs:DescribeLogStreams",   # Read log stream metadata
        ]
        Resource = "*"
      }
    ]
  })
}


# ── VPC FLOW LOG — THE ACTUAL CAMERA ───────────────────────
# This is what tells AWS: "record ALL traffic in this VPC"
# traffic_type = "ALL" captures both accepted AND rejected packets.
# Use "REJECT" if you only want to see blocked traffic (cheaper, less storage).
resource "aws_flow_log" "vpc" {
  vpc_id          = module.vpc.vpc_id
  traffic_type    = "ALL"                    # ACCEPT + REJECT — see everything
  iam_role_arn    = aws_iam_role.vpc_flow_logs.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs.arn

  # Log format: includes all default fields plus vpc-id for clarity
  # Each field is a column in the security camera footage
  log_format = "$${version} $${account-id} $${vpc-id} $${subnet-id} $${instance-id} $${interface-id} $${srcaddr} $${dstaddr} $${srcport} $${dstport} $${protocol} $${packets} $${bytes} $${start} $${end} $${action} $${log-status}"

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-vpc-flow-log"
  })
}


# ── CLOUDWATCH METRIC FILTER — ALERT ON REJECTED TRAFFIC ───
# This is like a motion detector on top of the security camera.
# It watches the footage and raises a flag when it sees rejected connections.
# REJECTED = someone tried to connect but was blocked by a security group.

resource "aws_cloudwatch_log_metric_filter" "rejected_connections" {
  name           = "${var.project_name}-${var.environment}-rejected-connections"
  log_group_name = aws_cloudwatch_log_group.vpc_flow_logs.name

  # Pattern: look for log lines where the action field is "REJECT"
  pattern = "[version, account_id, vpc_id, subnet_id, instance_id, interface_id, srcaddr, dstaddr, srcport, dstport, protocol, packets, bytes, start, end, action=\"REJECT\", log_status]"

  metric_transformation {
    name      = "RejectedConnections"
    namespace = "${var.project_name}/${var.environment}/VPCFlowLogs"
    value     = "1"   # count each rejected packet as 1
    unit      = "Count"
  }
}

# ── CLOUDWATCH ALARM — NOTIFY WHEN ATTACKS ARE DETECTED ────
# If there are more than 100 rejected connections in 5 minutes,
# something suspicious is happening (port scan, brute-force attempt, etc.)
# The alarm state will be visible in the AWS Console (CloudWatch → Alarms).
# To get email/SMS alerts, add an SNS topic ARN to alarm_actions below.
resource "aws_cloudwatch_metric_alarm" "high_rejected_connections" {
  alarm_name          = "${var.project_name}-${var.environment}-high-rejected-connections"
  alarm_description   = "More than 100 rejected network connections in 5 minutes — possible port scan or intrusion attempt"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "RejectedConnections"
  namespace           = "${var.project_name}/${var.environment}/VPCFlowLogs"
  period              = 300  # 5 minutes
  statistic           = "Sum"
  threshold           = 100
  treat_missing_data  = "notBreaching"  # no data = no alarm (don't alert when VPC is quiet)

  # SNS topic created in 70-monitoring layer — wired in here so security
  # alerts land in the same inbox as all other application alerts.
  alarm_actions = [data.aws_ssm_parameter.sns_alerts_arn.value]
  ok_actions    = [data.aws_ssm_parameter.sns_alerts_arn.value]

  tags = var.common_tags
}

# ── SNS TOPIC ARN (from 70-monitoring layer) ─────────────────
# Reads the SNS topic ARN stored by the 70-monitoring layer.
# Apply 70-monitoring BEFORE re-applying 00-vpc.
data "aws_ssm_parameter" "sns_alerts_arn" {
  name = "/${var.project_name}/${var.environment}/sns_alerts_arn"
}
