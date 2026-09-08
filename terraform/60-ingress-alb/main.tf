# ── ALB ────────────────────────────────────────────────────
resource "aws_lb" "ingress_alb" {
  name               = "${var.project_name}-${var.environment}-ingress-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [data.aws_ssm_parameter.ingress_sg_id.value]
  subnets            = split(",", data.aws_ssm_parameter.public_subnet_ids.value)

  enable_deletion_protection = false

  tags = merge(
    var.common_tags,
    {
      Name = "${var.project_name}-${var.environment}-ingress-alb"
    }
  )
}

# ── TARGET GROUP ────────────────────────────────────────────
resource "aws_lb_target_group" "frontend" {
  name        = "${var.project_name}-${var.environment}-frontend"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = data.aws_ssm_parameter.vpc_id.value

  health_check {
    path                = "/"
    port                = 8080
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }
}

# ── HTTP LISTENER (port 80) → redirect to HTTPS ─────────────
# Anyone visiting http://kwmbayu.com is automatically sent to https://kwmbayu.com
# The browser shows the padlock, traffic is encrypted. No manual step needed.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.ingress_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301" # permanent redirect — browsers remember this
    }
  }
}

# ── HTTPS LISTENER (port 443) → forward to app ──────────────
# The actual listener that serves the app over HTTPS.
# It uses the ACM certificate to encrypt traffic.
# The cert ARN is stored in SSM by the 50-acm layer.
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.ingress_alb.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06" # TLS 1.3 — most secure policy

  certificate_arn = data.aws_ssm_parameter.acm_certificate_arn.value

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}
