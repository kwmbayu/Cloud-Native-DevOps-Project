# ============================================================
# WAF — WEB APPLICATION FIREWALL
#
# What this does:
#   Puts a bouncer in front of the ALB.
#   Every HTTP request is inspected before reaching the app.
#   Known attacks are blocked automatically — the app never sees them.
#
# Rules applied (in order):
#   1. IP Reputation list    — block IPs AWS has flagged as malicious globally
#   2. Known Bad Inputs      — block Log4Shell, Spring4Shell, path traversal, etc.
#   3. Common Rule Set       — block OWASP Top 10 (SQL injection, XSS, etc.)
#   4. Rate limiter          — block any IP sending >2000 requests per 5 minutes
#
# Scope = REGIONAL because this WAF is attached to an ALB (not CloudFront).
# ============================================================


# ── WAF WEB ACL — THE RULEBOOK + BOUNCER ───────────────────
resource "aws_wafv2_web_acl" "alb" {
  name        = "${var.project_name}-${var.environment}-waf"
  description = "WAF for the ${var.project_name}-${var.environment} ALB — blocks common web attacks"
  scope       = "REGIONAL" # ALBs require REGIONAL scope (CLOUDFRONT is only for CF distributions)

  # Default action: ALLOW — requests that pass all rules get through
  # (we only block what we explicitly identify as bad)
  default_action {
    allow {}
  }

  # ── RULE 1: AWS IP REPUTATION LIST ─────────────────────
  # AWS maintains a global list of IPs known to be malicious:
  # botnets, scrapers, Tor exit nodes, known attack sources.
  # This blocks them before they even get to check the other rules.
  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 10  # lower number = checked first

    override_action {
      none {} # use the rule group's own actions (block)
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-${var.environment}-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  # ── RULE 2: KNOWN BAD INPUTS ───────────────────────────
  # Blocks requests containing patterns known to be exploits:
  # Log4Shell (CVE-2021-44228), Spring4Shell, path traversal (../../etc/passwd), etc.
  # These are zero-day exploit signatures maintained by AWS.
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-${var.environment}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # ── RULE 3: OWASP COMMON RULE SET ──────────────────────
  # Blocks the OWASP Top 10 most critical web application security risks:
  #   - SQL injection:         ' OR 1=1 --  (trying to manipulate the database)
  #   - Cross-site scripting:  <script>alert('hacked')</script>
  #   - Local file inclusion:  /etc/passwd, ../../config
  #   - Remote file inclusion: loading malicious scripts from external servers
  #   - HTTP protocol attacks: malformed headers, oversized requests
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 30

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
        # SizeRestrictions_BODY is excluded because it can block
        # legitimate file uploads. Re-enable if you don't need uploads.
        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use {
            count {} # count instead of block — prevents breaking file uploads
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-${var.environment}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  # ── RULE 4: RATE LIMITER ────────────────────────────────
  # If a single IP sends more than 2000 requests in 5 minutes, block it.
  # Normal users make maybe 10-50 requests. Bots make thousands.
  # This stops: DDoS attacks, credential stuffing, aggressive scrapers.
  rule {
    name     = "RateLimitPerIP"
    priority = 40

    action {
      block {} # block immediately — no counting, just drop
    }

    statement {
      rate_based_statement {
        limit              = 2000  # max requests per 5-minute window
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-${var.environment}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # ── VISIBILITY CONFIG ──────────────────────────────────
  # Top-level metrics for the entire WAF (all rules combined)
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-${var.environment}-waf"
    sampled_requests_enabled   = true  # keep 100 samples of blocked requests for inspection
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-waf"
  })
}


# ── WAF ASSOCIATION — ATTACH THE BOUNCER TO THE DOOR ───────
# Without this, the WAF exists but isn't watching any traffic.
# This line connects the WAF to the ALB.
resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.ingress_alb.arn
  web_acl_arn  = aws_wafv2_web_acl.alb.arn
}


# ── CLOUDWATCH ALARM — ALERT ON HIGH BLOCK RATE ────────────
# If WAF is blocking more than 50 requests per minute,
# something notable is happening (active attack or misconfigured rule).
resource "aws_cloudwatch_metric_alarm" "waf_blocked_requests" {
  alarm_name          = "${var.project_name}-${var.environment}-waf-high-blocks"
  alarm_description   = "WAF is blocking more than 50 requests/min — possible active attack or rule misconfiguration"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "BlockedRequests"
  namespace           = "AWS/WAFV2"
  period              = 60  # 1 minute
  statistic           = "Sum"
  threshold           = 50
  treat_missing_data  = "notBreaching"

  dimensions = {
    WebACL = aws_wafv2_web_acl.alb.name
    Region = "us-east-1"
    Rule   = "ALL"
  }

  # To get email/SMS alerts, add an SNS topic ARN here:
  alarm_actions = [data.aws_ssm_parameter.sns_alerts_arn.value]
  ok_actions    = [data.aws_ssm_parameter.sns_alerts_arn.value]

  tags = var.common_tags
}


# ── OUTPUT — WAF ARN ────────────────────────────────────────
output "waf_web_acl_arn" {
  description = "WAF Web ACL ARN — use this to associate WAF with additional resources"
  value       = aws_wafv2_web_acl.alb.arn
}
