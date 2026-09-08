# ============================================================
# DATA SOURCES — READ OUTPUTS FROM OTHER TERRAFORM LAYERS
#
# This layer depends on:
#   50-acm    → ACM certificate ARN (for HTTPS on CloudFront)
#   60-ingress-alb → ALB DNS name and zone ID (the CloudFront origin)
#
# Apply order: 50-acm → 60-ingress-alb → 65-cdn
# ============================================================

# ACM certificate ARN — written by 50-acm layer
# CloudFront uses this cert to serve kwmbayu.com over HTTPS.
# CloudFront REQUIRES certs to be in us-east-1 — this one already is.
data "aws_ssm_parameter" "acm_certificate_arn" {
  name = "/${var.project_name}/${var.environment}/acm_certificate_arn"
}

# ALB DNS name — written by 60-ingress-alb layer
# CloudFront will connect to the ALB using the "origin.kwmbayu.com" alias
# we create (see route53.tf). We still need the ALB DNS for that alias.
data "aws_ssm_parameter" "alb_dns_name" {
  name = "/${var.project_name}/${var.environment}/alb_dns_name"
}

# ALB zone ID — needed for Route 53 alias records pointing at the ALB
# (This is the ALB's own hosted zone ID, not your Route 53 hosted zone)
data "aws_ssm_parameter" "alb_zone_id" {
  name = "/${var.project_name}/${var.environment}/alb_zone_id"
}
