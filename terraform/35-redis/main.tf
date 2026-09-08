# ============================================================
# ELASTICACHE REDIS — IN-MEMORY CACHING LAYER
#
# What Redis is:
#   Redis is an in-memory database — it stores data in RAM, not on disk.
#   RAM is ~100x faster to read than a hard drive, so reads are microsecond-fast.
#   We use it as a cache sitting between the app and the RDS MySQL database.
#
# Cache flow:
#   Request arrives → check Redis for cached answer
#     ├── Cache HIT  → return cached data immediately (0 DB queries)
#     └── Cache MISS → query MySQL → store result in Redis → return data
#                                    (next request = cache hit)
#
# What we cache:
#   - GET /transaction     → all expenses (TTL: 5 minutes)
#   - GET /transaction/id  → single expense (TTL: 5 minutes)
#
# What we DON'T cache (and why we INVALIDATE after these):
#   - POST /transaction  → adds new data → old "all expenses" cache is wrong
#   - DELETE /transaction → removes data → old "all expenses" cache is wrong
#   After any write, the app deletes the relevant Redis keys so the next
#   request fetches fresh data from MySQL.
#
# Why cache.t3.micro:
#   - 0.5 vCPU, 512 MB RAM
#   - Handles ~65,000 connections
#   - Enough for hundreds of concurrent app users
#   - ~$12/month (the cheapest ElastiCache node — great for dev)
#
# Apply order: 00-vpc → 10-sg → 35-redis
# ============================================================


# ── SECURITY GROUP — CONTROLS WHO CAN TALK TO REDIS ─────────
# Redis listens on port 6379.
# We only allow traffic from EKS nodes — the app pods.
# Nothing else (bastion, VPN, internet) can reach Redis.
#
# No inbound rule from the internet means Redis is never exposed publicly,
# even if someone misconfigures something.
resource "aws_security_group" "redis" {
  name        = "${var.project_name}-${var.environment}-redis"
  description = "Allow Redis traffic from EKS nodes only"
  vpc_id      = data.aws_ssm_parameter.vpc_id.value

  # Inbound: only port 6379 from EKS nodes
  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [data.aws_ssm_parameter.node_sg_id.value]
    description     = "Redis from EKS nodes only — app pods connect here"
  }

  # Outbound: allow all (Redis needs to respond to requests)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-redis"
  })
}


# ── ELASTICACHE SUBNET GROUP — WHERE REDIS LIVES ────────────
# A subnet group tells ElastiCache which subnets it can use.
# We put Redis in the private subnets — same network as EKS nodes.
# Private subnets have no direct route to the internet, so Redis
# is unreachable from outside the VPC.
resource "aws_elasticache_subnet_group" "redis" {
  name        = "${var.project_name}-${var.environment}-redis"
  description = "Private subnets for ElastiCache Redis"
  subnet_ids  = split(",", data.aws_ssm_parameter.private_subnet_ids.value)

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-redis-subnet-group"
  })
}


# ── ELASTICACHE CLUSTER — THE ACTUAL REDIS NODE ─────────────
# This creates one Redis node (no replication for dev — replication
# is Multi-AZ and costs 2x; enable for production).
#
# engine_version = "7.1": Redis 7.1 — latest stable, supports all modern
#   data structures (strings, lists, hashes, sorted sets, streams).
#
# num_cache_nodes = 1: single node. For production, use
#   aws_elasticache_replication_group with 1 primary + 1 replica.
resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "${var.project_name}-${var.environment}-redis"
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = "cache.t3.micro"  # ~$12/month, 512MB RAM
  num_cache_nodes      = 1

  # Redis default port
  port                 = 6379

  # Use the private subnets we defined
  subnet_group_name    = aws_elasticache_subnet_group.redis.name

  # Only allow traffic from our Redis security group
  security_group_ids   = [aws_security_group.redis.id]

  # Maintenance window: apply patches at low-traffic time
  # 4:00-5:00 AM UTC on Tuesday = off-hours for most use cases
  maintenance_window   = "tue:04:00-tue:05:00"

  # Snapshot window: take daily backup at 3:00-4:00 AM
  # (Redis snapshots are RDB files — point-in-time backups of all cache data)
  snapshot_window      = "03:00-04:00"

  # Keep snapshots for 1 day.
  # In production, increase to 7+ days for disaster recovery.
  snapshot_retention_limit = 1

  # Apply updates automatically during the maintenance window.
  # Keeps the Redis version patched against security vulnerabilities.
  apply_immediately    = false

  # Notify SNS when a failover or other significant event happens
  notification_topic_arn = data.aws_ssm_parameter.sns_alerts_arn.value

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-redis"
  })
}


# ── SSM PARAMETERS — STORE REDIS DETAILS FOR THE APP ────────

# Redis endpoint (hostname) — the app connects to this address.
# Format: expense-dev-redis.xxxxxx.0001.use1.cache.amazonaws.com
resource "aws_ssm_parameter" "redis_host" {
  name        = "/${var.project_name}/${var.environment}/redis_host"
  type        = "String"
  value       = aws_elasticache_cluster.redis.cache_nodes[0].address
  description = "ElastiCache Redis endpoint — app connects here for caching"

  tags = var.common_tags
}

# Redis port — always 6379, stored for completeness
resource "aws_ssm_parameter" "redis_port" {
  name        = "/${var.project_name}/${var.environment}/redis_port"
  type        = "String"
  value       = tostring(aws_elasticache_cluster.redis.cache_nodes[0].port)
  description = "ElastiCache Redis port (6379)"

  tags = var.common_tags
}


# ── OUTPUTS ──────────────────────────────────────────────────
output "redis_host" {
  description = "Paste this into helm/values.yaml as config.redisHost (or set as DB_HOST equivalent in CI/CD)"
  value       = aws_elasticache_cluster.redis.cache_nodes[0].address
}

output "redis_port" {
  value = aws_elasticache_cluster.redis.cache_nodes[0].port
}
