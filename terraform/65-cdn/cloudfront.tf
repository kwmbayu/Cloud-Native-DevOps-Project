# ============================================================
# CLOUDFRONT DISTRIBUTION — GLOBAL CDN FOR THE EXPENSE APP
#
# What CloudFront does:
#   CloudFront is a Content Delivery Network (CDN).
#   It has 450+ "edge locations" around the world — mini-servers in
#   London, Tokyo, São Paulo, Sydney, Mumbai, etc.
#
#   Without CloudFront:
#     A user in London requests your logo → request travels to Virginia →
#     image travels back to London → user waits ~200ms
#
#   With CloudFront:
#     First user in London requests logo → travels to Virginia, cached at
#     London edge location.
#     Every user after that → served from London → user waits ~5ms
#
# What we cache vs. what we pass through:
#   ┌─────────────────────────────────────────────────────────┐
#   │ CACHED at edge (static assets — never changes per user) │
#   │   /images/*  /css/*  /js/*  /static/*                  │
#   │   → served instantly from nearest city                  │
#   ├─────────────────────────────────────────────────────────┤
#   │ NOT CACHED (dynamic content — unique per request)       │
#   │   /api/*  /  everything else                            │
#   │   → forwarded through to ALB → EKS pod                 │
#   └─────────────────────────────────────────────────────────┘
#
# How CloudFront connects to the ALB (the clever bit):
#   CloudFront needs HTTPS to verify it's talking to the real ALB.
#   But the ALB cert is for "kwmbayu.com" — and if CF connects to
#   "expense-dev-ingress-alb-xxx.us-east-1.elb.amazonaws.com", the
#   cert doesn't match → SSL error.
#
#   Solution: we create a private subdomain "origin.kwmbayu.com" → ALB
#   (see route53.tf). The ACM cert covers "*.kwmbayu.com", so
#   "origin.kwmbayu.com" matches it perfectly.
#
#   CloudFront → HTTPS → origin.kwmbayu.com → ALB cert matches ✅
#   Users never know this URL exists — only CloudFront uses it.
#
# ── CLOUDFRONT MANAGED CACHE POLICY IDs (AWS-provided) ──────
# These are pre-built policies that AWS maintains. Using them is
# better than creating custom ones from scratch.
#
#   CachingDisabled     = 4135ea2d-6df8-44a3-9df3-4b5a84be39ad
#     → Cache nothing. Every request goes to the origin (ALB).
#     → Used for dynamic content: API calls, form submissions.
#
#   CachingOptimized    = 658327ea-f89d-4fab-a63d-7e88639e58f6
#     → Cache everything. TTL = 24 hours by default.
#     → Compress files (gzip/brotli) automatically.
#     → Used for static assets: images, CSS, JS.
#
#   AllViewerExceptHostHeader = b689b0a8-53d0-40ab-baf2-68738e2966ac
#     → Forward all request details to origin (query strings, cookies,
#       headers) EXCEPT the Host header (CF sets that to origin domain).
#     → Used for dynamic requests so ALB sees everything.
# ============================================================


resource "aws_cloudfront_distribution" "expense" {

  comment = "CDN for ${var.project_name}-${var.environment} — caches static assets globally"
  enabled = true

  # The domain names this CloudFront distribution accepts.
  # Users type "kwmbayu.com" → CloudFront serves it.
  # Without these aliases, only the cloudfront.net domain would work.
  aliases = [
    var.zone_name,          # kwmbayu.com
    "www.${var.zone_name}"  # www.kwmbayu.com
  ]

  # Default root object — when someone visits https://kwmbayu.com/
  # CloudFront asks the origin for "index.html" automatically.
  default_root_object = "index.html"

  # Price class controls which edge locations are used.
  # PriceClass_100 = US, Canada, Europe, Israel — cheapest option.
  # Covers the majority of users. Switch to PriceClass_All for worldwide.
  # First 1TB/month of data transfer is FREE regardless of price class.
  price_class = "PriceClass_100"

  # ── ORIGIN — WHERE CLOUDFRONT SENDS UNCACHED REQUESTS ──────
  # This is the "source of truth" for content.
  # CloudFront checks its cache first. If no cached copy exists,
  # it fetches from this origin (your ALB) and caches the response.
  #
  # We use "origin.kwmbayu.com" (not the raw ALB DNS) so the HTTPS
  # certificate matches. See the comment at the top for why.
  origin {
    domain_name = "origin.${var.zone_name}"  # origin.kwmbayu.com → ALB
    origin_id   = "expense-alb"              # internal label CloudFront uses

    custom_origin_config {
      http_port  = 80
      https_port = 443

      # https-only: CloudFront always uses HTTPS to talk to the ALB.
      # This encrypts traffic even inside AWS's network.
      origin_protocol_policy = "https-only"

      # Accept TLS 1.2 only — modern and secure.
      origin_ssl_protocols = ["TLSv1.2"]

      # How long CloudFront waits for the ALB to respond.
      # 30s = plenty for the app, but not so long the user thinks it's broken.
      origin_read_timeout      = 30
      origin_keepalive_timeout = 5
    }
  }

  # ── DEFAULT BEHAVIOR — DYNAMIC CONTENT (NOT CACHED) ─────────
  # Applied to all requests that don't match any of the
  # ordered_cache_behavior rules below.
  # API calls, form submissions, the homepage — all pass through to ALB.
  default_cache_behavior {
    target_origin_id = "expense-alb"

    # redirect-to-https: if a user types "http://kwmbayu.com",
    # CloudFront automatically redirects them to "https://kwmbayu.com".
    # The user always gets HTTPS, even if they type HTTP.
    viewer_protocol_policy = "redirect-to-https"

    # Allow all HTTP methods so the app can receive POST, PUT, DELETE etc.
    # (e.g., submitting a new expense, updating a record)
    allowed_methods = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods  = ["GET", "HEAD"]

    # CachingDisabled — don't cache. Every request goes to the ALB.
    cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"

    # AllViewerExceptHostHeader — forward everything from the user's request
    # to the ALB (query strings, cookies, headers) so the app sees real data.
    # Except Host header (CF sets that to "origin.kwmbayu.com").
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac"

    # Compress responses automatically (gzip/brotli).
    # HTML, JSON, CSS already compress well — usually 60-80% smaller.
    compress = true
  }

  # ── ORDERED CACHE BEHAVIORS — STATIC ASSETS (CACHED) ────────
  # These rules are checked IN ORDER before the default behavior.
  # If a request path matches, these settings apply instead.
  #
  # Why separate rules? Static files (images, CSS, JS) never change
  # between users. We can cache them aggressively — serve from the
  # nearest edge location, zero load on the ALB.
  #
  # Priority: lower index = checked first.

  # /images/* — profile photos, logos, screenshots (if any)
  ordered_cache_behavior {
    path_pattern     = "/images/*"
    target_origin_id = "expense-alb"

    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]

    # CachingOptimized: default TTL = 24 hours, max = 1 year.
    # Compress automatically (PNG → compressed if applicable).
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    compress        = true
  }

  # /css/* — stylesheets (Bootstrap, custom CSS)
  ordered_cache_behavior {
    path_pattern     = "/css/*"
    target_origin_id = "expense-alb"

    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]

    # CSS compresses extremely well — often 70-80% smaller.
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    compress        = true
  }

  # /js/* — JavaScript bundles (React, Angular, custom scripts)
  ordered_cache_behavior {
    path_pattern     = "/js/*"
    target_origin_id = "expense-alb"

    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]

    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    compress        = true
  }

  # /static/* — catch-all for any static asset directory
  ordered_cache_behavior {
    path_pattern     = "/static/*"
    target_origin_id = "expense-alb"

    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]

    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    compress        = true
  }

  # ── SSL/TLS CERTIFICATE ──────────────────────────────────────
  # The ACM certificate from 50-acm layer covers kwmbayu.com and *.kwmbayu.com.
  # CloudFront presents this cert to browsers — they see the padlock.
  #
  # sni-only: SNI = Server Name Indication. All modern browsers support it.
  # (The only alternative is "vip" which costs $600/month — don't use it.)
  #
  # TLSv1.2_2021: Only accept TLS 1.2 and 1.3. Blocks old, insecure
  # TLS 1.0 and 1.1 connections. Compatible with all modern browsers.
  viewer_certificate {
    acm_certificate_arn      = data.aws_ssm_parameter.acm_certificate_arn.value
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  # ── GEO RESTRICTIONS ────────────────────────────────────────
  # No country blocking — the expense app is available worldwide.
  # If needed, you can block specific countries with:
  #   restriction_type = "blacklist"
  #   locations        = ["RU", "CN", "KP"]
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # ── CUSTOM ERROR RESPONSES ───────────────────────────────────
  # When the origin (ALB/app) returns a 404 or 403, instead of showing
  # CloudFront's default error page, return the app's own error handling.
  #
  # error_caching_min_ttl = 10: cache error responses for only 10 seconds.
  # This means if the app recovers from an error, CloudFront picks it up
  # quickly instead of serving the error page for hours.
  custom_error_response {
    error_code            = 404
    error_caching_min_ttl = 10
    response_code         = 404
    response_page_path    = "/index.html"  # SPA fallback — React/Angular router handles it
  }

  custom_error_response {
    error_code            = 403
    error_caching_min_ttl = 10
    response_code         = 403
    response_page_path    = "/index.html"
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-cloudfront"
  })
}


# ── OUTPUT — PRINT THE CLOUDFRONT DOMAIN ────────────────────
# The CloudFront domain looks like: d1abc123xyz.cloudfront.net
# Before DNS propagates (can take 5-30 min), you can test at this URL.
output "cloudfront_domain" {
  description = "CloudFront domain (use for testing before DNS propagates)"
  value       = aws_cloudfront_distribution.expense.domain_name
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID — use for cache invalidations"
  value       = aws_cloudfront_distribution.expense.id
}
