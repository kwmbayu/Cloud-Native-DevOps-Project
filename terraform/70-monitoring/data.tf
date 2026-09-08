# ── LOOK UP THE ALB ─────────────────────────────────────────
# CloudWatch needs the ALB's internal ID (called arn_suffix) to know
# which load balancer to watch. We look it up by name.
# The name comes from 60-ingress-alb/main.tf: "${project}-${env}-ingress-alb"
data "aws_lb" "ingress" {
  name = "${var.project_name}-${var.environment}-ingress-alb"
}

# ── LOOK UP THE TARGET GROUP ─────────────────────────────────
# The "UnHealthyHostCount" alarm watches a Target Group, not the ALB itself.
# A Target Group is the list of pods the ALB sends traffic to.
# We look it up by name from 60-ingress-alb/main.tf.
data "aws_lb_target_group" "frontend" {
  name = "${var.project_name}-${var.environment}-frontend"
}
