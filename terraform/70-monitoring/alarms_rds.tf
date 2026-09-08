# ============================================================
# RDS ALARMS — WATCHING THE DATABASE
#
# The database is the most critical part of the expense app.
# If it goes down or becomes overloaded, the whole app breaks.
#
# Three things we watch:
#   1. CPU too high       — database is overloaded
#   2. Storage running low — disk will fill up and crash the DB
#   3. Too many connections — database can't accept more requests
# ============================================================

locals {
  # The RDS instance identifier — matches what was set in 30-db/main.tf
  # "${var.project_name}-${var.environment}" = "expense-dev"
  rds_identifier = "${var.project_name}-${var.environment}"
}


# ── ALARM 1: HIGH CPU ────────────────────────────────────────
# What this measures:
#   What percentage of the database server's processing power is being used.
#   0-60%  = normal, plenty of headroom
#   60-80% = getting busy, keep an eye on it
#   80%+   = overloaded — queries will slow down, app will feel sluggish
#
# db.t3.micro has 2 vCPUs. At 80% CPU, complex queries start queueing up.
resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "${var.project_name}-${var.environment}-rds-cpu-high"
  alarm_description   = "RDS CPU above 80%. The database is overloaded — check for slow queries or consider upgrading instance class."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3        # 3 consecutive bad readings (15 min) before alerting
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300      # 5-minute window
  statistic           = "Average"
  threshold           = 80       # percent

  dimensions = {
    DBInstanceIdentifier = local.rds_identifier
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = var.common_tags
}


# ── ALARM 2: LOW FREE STORAGE ────────────────────────────────
# What this measures:
#   How much disk space is left on the RDS instance.
#   The database was created with 5GB total storage.
#   When it hits 0%, MySQL stops accepting writes — app crashes.
#
# Threshold: alert when less than 1GB remains (20% of 5GB).
# That gives you time to either:
#   a) Enable "storage autoscaling" in RDS (increases disk automatically)
#   b) Delete old data
#   c) Upgrade to a larger storage size
#
# 1GB in bytes = 1,073,741,824 bytes (CloudWatch uses bytes for this metric)
resource "aws_cloudwatch_metric_alarm" "rds_low_storage" {
  alarm_name          = "${var.project_name}-${var.environment}-rds-low-storage"
  alarm_description   = "RDS free storage below 1GB (out of 5GB total). Enable storage autoscaling or clean up data."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1        # alert immediately — storage doesn't fluctuate
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 1073741824   # 1 GB in bytes

  dimensions = {
    DBInstanceIdentifier = local.rds_identifier
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = var.common_tags
}


# ── ALARM 3: TOO MANY CONNECTIONS ────────────────────────────
# What this measures:
#   How many open connections the database currently has.
#   Each request from the app opens a connection to the database.
#   db.t3.micro supports a maximum of about 90 connections.
#
# Why it matters:
#   If connections hit the limit, new requests fail with
#   "Too many connections" error. The whole app stops working.
#
# Threshold: alert at 80 connections (88% of max).
# That gives you ~10 connection slots before total failure.
resource "aws_cloudwatch_metric_alarm" "rds_high_connections" {
  alarm_name          = "${var.project_name}-${var.environment}-rds-high-connections"
  alarm_description   = "RDS has 80+ open connections (max ~90 for db.t3.micro). App may start seeing connection errors."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80

  dimensions = {
    DBInstanceIdentifier = local.rds_identifier
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = var.common_tags
}
