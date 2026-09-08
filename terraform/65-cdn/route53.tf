# ============================================================
# ROUTE 53 — DNS RECORDS FOR CLOUDFRONT
#
# This file manages three DNS records:
#
#   1. kwmbayu.com         → CloudFront (users hit CF, not ALB directly)
#   2. www.kwmbayu.com     → CloudFront (same)
#   3. origin.kwmbayu.com  → ALB        (private; only CloudFront knows this)
#
# Why three records?
#   kwmbayu.com and www → CloudFront:
#     Users get the CDN benefits — cached static assets, global edge locations.
#
#   origin.kwmbayu.com → ALB:
#     This is the "back door" that only CloudFront knows about.
#     The ACM cert covers *.kwmbayu.com, which matches origin.kwmbayu.com.
#     This lets CloudFront use HTTPS to talk to the ALB without a cert mismatch.
#     Users never see or use this URL.
#
# BEFORE APPLYING THIS:
#   The 50-acm layer used to manage kwmbayu.com and www.kwmbayu.com records
#   (pointing at the ALB). Those have been removed from 50-acm. If you're
#   migrating an existing deployment:
#     1. Apply 50-acm (to remove its Route 53 records from Terraform state)
#        → Actually, run: terraform -chdir=terraform/50-acm state rm aws_route53_record.root
#        →               terraform -chdir=terraform/50-acm state rm aws_route53_record.www
#     2. Apply 65-cdn (creates new records pointing at CloudFront)
#   For a fresh deployment: just apply in order — 50-acm → 60-ingress-alb → 65-cdn
# ============================================================


# ── RECORD 1: kwmbayu.com → CLOUDFRONT ──────────────────────
# Alias A record pointing the root domain at CloudFront.
# Alias records (not CNAMEs) are required for root domains.
# CloudFront has its own hosted zone ID: Z2FDTNDATAQYW2 (global, always this value)
resource "aws_route53_record" "root" {
  zone_id = var.zone_id
  name    = var.zone_name   # kwmbayu.com
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.expense.domain_name
    zone_id                = "Z2FDTNDATAQYW2"  # CloudFront's fixed hosted zone ID (AWS-standard)
    evaluate_target_health = false  # CloudFront manages its own health; Route 53 doesn't check it
  }
}

# ── RECORD 2: www.kwmbayu.com → CLOUDFRONT ──────────────────
resource "aws_route53_record" "www" {
  zone_id = var.zone_id
  name    = "www.${var.zone_name}"   # www.kwmbayu.com
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.expense.domain_name
    zone_id                = "Z2FDTNDATAQYW2"
    evaluate_target_health = false
  }
}

# ── RECORD 3: origin.kwmbayu.com → ALB ──────────────────────
# The private origin subdomain that only CloudFront uses.
# Users never visit this URL — it's the hidden back door.
#
# Why this instead of the raw ALB DNS name?
#   The ACM cert covers *.kwmbayu.com (wildcard).
#   "origin.kwmbayu.com" matches "*.kwmbayu.com" ✅
#   "expense-dev-ingress-alb-xxx.us-east-1.elb.amazonaws.com" does NOT ❌
#
# So by routing through this subdomain, CloudFront can verify the ALB's
# certificate and establish a trusted HTTPS connection.
resource "aws_route53_record" "origin" {
  zone_id = var.zone_id
  name    = "origin.${var.zone_name}"  # origin.kwmbayu.com
  type    = "A"

  alias {
    name                   = data.aws_ssm_parameter.alb_dns_name.value
    zone_id                = data.aws_ssm_parameter.alb_zone_id.value
    evaluate_target_health = true  # if ALB is unhealthy, Route 53 won't route to it
  }
}
