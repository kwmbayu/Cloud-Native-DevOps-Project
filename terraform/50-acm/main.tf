# ============================================================
# LAYER 50 — ACM SSL CERTIFICATE + DNS VALIDATION
#
# What this does:
#   Requests a free SSL/TLS certificate from AWS Certificate Manager (ACM).
#   SSL = the padlock in the browser address bar.
#   Without this, the site runs on HTTP (unencrypted).
#   With this, it runs on HTTPS (all traffic is encrypted in transit).
#
# How certificate validation works:
#   AWS needs to prove you own the domain before issuing a cert.
#   Method = DNS validation: AWS gives you a special DNS record to add.
#   We add it to Route 53 automatically. AWS checks it and issues the cert.
#   This happens without any manual steps.
#
# Covers:
#   - kwmbayu.com          (the root domain)
#   - *.kwmbayu.com        (wildcard — covers www.kwmbayu.com etc.)
# ============================================================


# ── THE CERTIFICATE REQUEST ─────────────────────────────────
# Think of this like applying for a passport.
# You submit the application, AWS verifies your identity (via DNS),
# then issues the cert. It's free and auto-renews every 13 months.
resource "aws_acm_certificate" "expense" {
  domain_name               = var.zone_name          # kwmbayu.com
  subject_alternative_names = ["*.${var.zone_name}"] # *.kwmbayu.com (covers www etc.)
  validation_method         = "DNS"                  # prove ownership via DNS record

  # Allow Terraform to replace the cert if the domain list changes
  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-acm"
  })
}


# ── DNS VALIDATION RECORD ───────────────────────────────────
# AWS tells us exactly what DNS record to add to prove we own the domain.
# We create that record automatically in Route 53.
# Once AWS sees the record, it issues the certificate (usually 2-5 minutes).
resource "aws_route53_record" "acm_validation" {
  # The certificate may return multiple validation records (one per domain name).
  # We create one Route 53 record for each.
  for_each = {
    for dvo in aws_acm_certificate.expense.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id = var.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60  # low TTL so AWS can verify quickly
}


# ── CERTIFICATE VALIDATION (WAIT FOR ISSUANCE) ─────────────
# This resource tells Terraform:
# "Don't continue until the certificate is fully issued."
# Without this, Terraform might try to attach a pending cert to the ALB.
resource "aws_acm_certificate_validation" "expense" {
  certificate_arn         = aws_acm_certificate.expense.arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation : record.fqdn]

  timeouts {
    create = "30m" # wait up to 30 min for cert issuance (usually 2-5 min)
  }
}


# ── ROUTE 53 A RECORDS — MOVED TO 65-CDN LAYER ──────────────
# The DNS A records for kwmbayu.com and www.kwmbayu.com used to live
# here, pointing at the ALB directly.
#
# They have been moved to terraform/65-cdn/route53.tf, where they
# now point at CloudFront instead of the ALB.
#
# Traffic flow after 65-cdn is applied:
#   kwmbayu.com → CloudFront → origin.kwmbayu.com → ALB → EKS
#
# If you are running WITHOUT CloudFront (65-cdn not applied), you can
# temporarily add these records back here to test:
#   data "aws_ssm_parameter" "alb_dns_name" {
#     name = "/${var.project_name}/${var.environment}/alb_dns_name"
#   }
#   data "aws_ssm_parameter" "alb_zone_id" {
#     name = "/${var.project_name}/${var.environment}/alb_zone_id"
#   }
#   resource "aws_route53_record" "root" { ... }
#   resource "aws_route53_record" "www"  { ... }
#
# MIGRATION NOTE (existing deployments only):
#   If you applied 50-acm before adding 65-cdn, Terraform state still
#   thinks it owns those Route 53 records. Before applying 65-cdn, remove
#   them from 50-acm's state (does NOT delete from AWS):
#     terraform -chdir=terraform/50-acm state rm aws_route53_record.root
#     terraform -chdir=terraform/50-acm state rm aws_route53_record.www
#   Then: terraform apply in 65-cdn creates them pointing at CloudFront.
