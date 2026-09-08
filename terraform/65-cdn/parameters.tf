# ============================================================
# SSM PARAMETERS — STORE CDN OUTPUTS FOR OTHER LAYERS
#
# Store the CloudFront domain and distribution ID in SSM so
# other tools (CI/CD, monitoring, scripts) can find them without
# hard-coding values.
# ============================================================

# CloudFront domain name (e.g. d1abc123xyz.cloudfront.net)
# Useful for testing before DNS propagates.
resource "aws_ssm_parameter" "cloudfront_domain" {
  name        = "/${var.project_name}/${var.environment}/cloudfront_domain"
  type        = "String"
  value       = aws_cloudfront_distribution.expense.domain_name
  description = "CloudFront domain for ${var.project_name}-${var.environment}"

  tags = var.common_tags
}

# CloudFront distribution ID — needed to invalidate cache after deployments.
# When you deploy new code, old files might be cached at edge locations.
# Invalidation tells CloudFront: "clear your cache, fetch fresh files from origin."
#
# How to invalidate after a deploy:
#   aws cloudfront create-invalidation \
#     --distribution-id $(aws ssm get-parameter --name /expense/dev/cloudfront_distribution_id --query Parameter.Value --output text) \
#     --paths "/*"
#
# The GitHub Actions CI/CD pipeline should run this after every deploy
# so users always get the latest files.
resource "aws_ssm_parameter" "cloudfront_distribution_id" {
  name        = "/${var.project_name}/${var.environment}/cloudfront_distribution_id"
  type        = "String"
  value       = aws_cloudfront_distribution.expense.id
  description = "CloudFront distribution ID — use for cache invalidations after deploys"

  tags = var.common_tags
}
