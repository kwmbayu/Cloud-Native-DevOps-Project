# ============================================================
# ALB ALARMS — WATCHING THE FRONT DOOR
#
# These alarms watch the Application Load Balancer — the front
# door of the expense app. If anything goes wrong with traffic
# flowing in or out, you get an email.
#
# Three things we watch:
#   1. 5xx errors   — the app is crashing (server-side errors)
#   2. Slow responses — the app is responding but very slowly
#   3. Unhealthy hosts — pods aren't passing their health check
# ============================================================


# ── ALARM 1: HIGH 5XX ERROR RATE ────────────────────────────
# What 5xx means:
#   HTTP response codes starting with 5 mean "the SERVER broke."
#   Examples: 500 Internal Server Error, 502 Bad Gateway, 503 Service Unavailable.
#   These are errors caused by YOUR app, not the user.
#   If users are getting 5xx responses, they're seeing error pages.
#
# Threshold: more than 10 errors in a 5-minute window.
# That's generous enough to ignore occasional blips but catches real problems.
resource "aws_cloudwatch_metric_alarm" "alb_5xx_errors" {
  alarm_name          = "${var.project_name}-${var.environment}-alb-5xx-errors"
  alarm_description   = "ALB is returning 5xx errors — the app may be crashing. Check pod logs."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2        # alarm only fires after 2 consecutive bad periods
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300      # 5 minutes (300 seconds)
  statistic           = "Sum"
  threshold           = 10       # more than 10 errors in 5 min → alert

  dimensions = {
    LoadBalancer = data.aws_lb.ingress.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]   # send email when alarm fires
  ok_actions    = [aws_sns_topic.alerts.arn]   # send email when it recovers

  treat_missing_data = "notBreaching"   # no data = probably quiet, not an error

  tags = var.common_tags
}


# ── ALARM 2: HIGH RESPONSE TIME ─────────────────────────────
# What this measures:
#   The time between when the ALB forwards a request to a pod
#   and when the pod sends back a response.
#   Under 500ms = fast. Under 2 seconds = acceptable. Over 2 seconds = slow.
#
# Why it matters:
#   Users feel anything over 2 seconds. If the app is slow, it means
#   the database is struggling, the pod is overloaded, or there's a
#   code problem causing slow queries.
resource "aws_cloudwatch_metric_alarm" "alb_response_time" {
  alarm_name          = "${var.project_name}-${var.environment}-alb-slow-responses"
  alarm_description   = "App response time exceeded 2 seconds. Check DB performance and pod CPU."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Average"
  threshold           = 2.0      # average response time > 2 seconds → alert

  dimensions = {
    LoadBalancer = data.aws_lb.ingress.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  treat_missing_data = "notBreaching"

  tags = var.common_tags
}


# ── ALARM 3: UNHEALTHY HOSTS ────────────────────────────────
# What this measures:
#   The number of pods that are FAILING their health check.
#   Remember the readiness probe we added? If a pod fails it 3 times,
#   the ALB marks it "unhealthy" and stops sending it traffic.
#
# Why it matters:
#   Even 1 unhealthy host means one of your pods is sick.
#   With only 2 pods (minReplicas=2), 1 unhealthy = 50% of your capacity gone.
#   You want to know immediately so you can check what's wrong.
resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_hosts" {
  alarm_name          = "${var.project_name}-${var.environment}-alb-unhealthy-hosts"
  alarm_description   = "One or more pods are failing health checks. Check pod logs in EKS."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60       # check every 60 seconds — faster detection
  statistic           = "Maximum"
  threshold           = 1        # even 1 unhealthy host → alert

  dimensions = {
    LoadBalancer = data.aws_lb.ingress.arn_suffix
    TargetGroup  = data.aws_lb_target_group.frontend.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  treat_missing_data = "notBreaching"

  tags = var.common_tags
}
