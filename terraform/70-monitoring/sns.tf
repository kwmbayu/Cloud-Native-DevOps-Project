# ============================================================
# SNS TOPIC — THE NOTIFICATION HUB
#
# What SNS is:
#   SNS = Simple Notification Service.
#   Think of it like a group chat for AWS alarms.
#   When any alarm fires, it sends a message to this "group chat."
#   Anyone subscribed to the group chat (your email) gets the message.
#
# Why we need this:
#   Without SNS, CloudWatch alarms just change colour in the console.
#   Nobody gets emailed. Nobody knows. The app could be down for hours.
#   With SNS, the moment something goes wrong, you get an email.
# ============================================================

resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-${var.environment}-alerts"

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-alerts"
  })
}

# ── EMAIL SUBSCRIPTION ──────────────────────────────────────
# This subscribes your email to the group chat.
# After terraform apply, AWS sends a confirmation email.
# YOU MUST CLICK "Confirm subscription" in that email,
# otherwise alarms will fire but no email is delivered.
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── STORE SNS ARN IN SSM ────────────────────────────────────
# Save the SNS topic ARN so other Terraform layers can find it
# and wire their own alarms into the same notification hub.
resource "aws_ssm_parameter" "sns_alerts_arn" {
  name  = "/${var.project_name}/${var.environment}/sns_alerts_arn"
  type  = "String"
  value = aws_sns_topic.alerts.arn

  tags = var.common_tags
}
