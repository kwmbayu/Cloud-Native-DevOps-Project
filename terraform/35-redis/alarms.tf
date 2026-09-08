# ============================================================
# CLOUDWATCH ALARMS — WATCHING THE REDIS CACHE
#
# Two things that tell you Redis is struggling:
#
#   1. High Memory Usage (> 80%)
#      cache.t3.micro has 512MB RAM. When it fills up, Redis starts
#      EVICTING (deleting) cached entries to make room. Evictions mean
#      cache misses → more database queries → slower app.
#
#   2. High Evictions
#      An eviction means Redis deleted a cached item before its TTL
#      expired, because it ran out of memory. A flood of evictions
#      means the cache is overwhelmed — time to upgrade the node size.
#
# Both alarms send email via SNS (same topic as the ALB/RDS alarms).
# ============================================================

locals {
  redis_cluster_id = aws_elasticache_cluster.redis.cluster_id
}


# ── ALARM 1: HIGH MEMORY USAGE ───────────────────────────────
# BytesUsedForCache / total memory > 80% → Redis is almost full.
# cache.t3.micro: 512MB total. 80% threshold = ~410MB.
#
# What happens when Redis runs out of memory:
#   It starts deleting cached items (evictions). The next request for
#   that item misses the cache and hits MySQL instead — performance drops.
#
# CloudWatch metric: FreeableMemory (the RAM Redis hasn't used yet)
# Threshold: alert when less than 100MB is free (out of 512MB = ~80% used)
# 100MB in bytes = 104857600
resource "aws_cloudwatch_metric_alarm" "redis_high_memory" {
  alarm_name          = "${var.project_name}-${var.environment}-redis-high-memory"
  alarm_description   = "Redis memory above 80% — cache may start evicting entries. Consider upgrading to cache.t3.small."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "FreeableMemory"
  namespace           = "AWS/ElastiCache"
  period              = 300   # 5-minute window
  statistic           = "Average"
  threshold           = 104857600   # 100MB free = ~80% used on t3.micro

  dimensions = {
    CacheClusterId = local.redis_cluster_id
  }

  alarm_actions = [data.aws_ssm_parameter.sns_alerts_arn.value]
  ok_actions    = [data.aws_ssm_parameter.sns_alerts_arn.value]

  treat_missing_data = "notBreaching"

  tags = var.common_tags
}


# ── ALARM 2: HIGH EVICTIONS ───────────────────────────────────
# An eviction = Redis deleted a cached item because it ran out of space.
# Even a small number of evictions per minute means the cache is under pressure.
#
# Threshold: more than 100 evictions in a 5-minute window.
# For a small app, any evictions are a warning sign.
resource "aws_cloudwatch_metric_alarm" "redis_high_evictions" {
  alarm_name          = "${var.project_name}-${var.environment}-redis-high-evictions"
  alarm_description   = "Redis is evicting cached items — memory is full. More database queries are hitting MySQL."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Evictions"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Sum"
  threshold           = 100   # more than 100 evictions in 5 min → alert

  dimensions = {
    CacheClusterId = local.redis_cluster_id
  }

  alarm_actions = [data.aws_ssm_parameter.sns_alerts_arn.value]
  ok_actions    = [data.aws_ssm_parameter.sns_alerts_arn.value]

  treat_missing_data = "notBreaching"

  tags = var.common_tags
}
