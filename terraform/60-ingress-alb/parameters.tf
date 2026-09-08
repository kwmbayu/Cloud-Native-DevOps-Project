# HTTP listener ARN (used by EKS ingress rules)
resource "aws_ssm_parameter" "web_alb_listener_arn" {
  name  = "/${var.project_name}/${var.environment}/web_alb_listener_arn"
  type  = "String"
  value = aws_lb_listener.http.arn
}

# HTTPS listener ARN
resource "aws_ssm_parameter" "web_alb_listener_arn_https" {
  name  = "/${var.project_name}/${var.environment}/web_alb_listener_arn_https"
  type  = "String"
  value = aws_lb_listener.https.arn
}

# ALB DNS name — used by 50-acm to create Route 53 alias records
resource "aws_ssm_parameter" "alb_dns_name" {
  name  = "/${var.project_name}/${var.environment}/alb_dns_name"
  type  = "String"
  value = aws_lb.ingress_alb.dns_name
}

# ALB hosted zone ID — used by 50-acm to create Route 53 alias records
# (This is the ALB's own zone ID, different from your Route 53 hosted zone)
resource "aws_ssm_parameter" "alb_zone_id" {
  name  = "/${var.project_name}/${var.environment}/alb_zone_id"
  type  = "String"
  value = aws_lb.ingress_alb.zone_id
}

output "alb_dns_name" {
  value       = aws_lb.ingress_alb.dns_name
  description = "Access the app at https://kwmbayu.com (or http://<alb_dns_name> before DNS propagates)"
}
