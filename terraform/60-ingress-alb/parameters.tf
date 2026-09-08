resource "aws_ssm_parameter" "web_alb_listener_arn" {
  name  = "/${var.project_name}/${var.environment}/web_alb_listener_arn"
  type  = "String"
  value = aws_lb_listener.http.arn
}

# HTTPS listener SSM parameter — commented out until domain is renewed and
# ACM certificate is active. Uncomment after enabling HTTPS in main.tf.
# resource "aws_ssm_parameter" "web_alb_listener_arn_https" {
#   name  = "/${var.project_name}/${var.environment}/web_alb_listener_arn_https"
#   type  = "String"
#   value = aws_lb_listener.https.arn
# }