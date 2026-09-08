# ============================================================
# VPC ENDPOINTS — PRIVATE TUNNELS TO AWS SERVICES
#
# Problem without endpoints:
#   Resources in private subnets (EKS nodes, RDS, Redis) cannot reach
#   AWS services (ECR, SSM, CloudWatch) directly. They route through
#   the NAT Gateway, which charges $0.045/GB of data transferred.
#   Every Docker image pull, every log batch, every SSM session keystroke
#   goes through NAT and costs money.
#
# Solution — VPC Endpoints:
#   A VPC Endpoint is a private tunnel between your VPC and an AWS service.
#   Traffic never leaves AWS's internal network. No NAT. No internet.
#   No per-GB charge.
#
# Analogy:
#   Without endpoints: to get a package from the warehouse (ECR), the
#   delivery van leaves your building (VPC), drives on public roads (internet),
#   reaches the warehouse, and drives back — paying a toll (NAT charge) both ways.
#
#   With endpoints: AWS builds a private loading dock directly connecting
#   your building to the warehouse. No roads, no toll, no charge per package.
#
# TWO TYPES of VPC Endpoints:
#
#   1. Gateway Endpoint (FREE):
#      Only available for S3 and DynamoDB.
#      Works by adding a route to your route tables — no ENI, no hourly cost.
#      Always use these. There is no reason not to.
#
#   2. Interface Endpoint (~$7-15/month each):
#      Creates a private network interface (ENI) inside your subnets.
#      Available for most AWS services: ECR, SSM, CloudWatch Logs, etc.
#      Cost = $0.01/hour per AZ the endpoint is deployed in.
#      With 2 private subnets (2 AZs): 2 × $0.01 × 730h = ~$14.60/month each.
#      Worth it when NAT data charges would exceed this.
#
# ENDPOINTS CREATED HERE:
#   S3           — Gateway (FREE) — ECR layers live in S3; every docker pull hits S3
#   ECR API      — Interface — authentication and ECR API calls
#   ECR DKR      — Interface — docker push/pull data
#   SSM          — Interface — SSM agent ↔ Systems Manager (our bastion replacement)
#   SSM Messages — Interface — Session Manager shell sessions
#   EC2 Messages — Interface — SSM agent heartbeats
#   CloudWatch Logs — Interface — Fluent Bit log shipping (constant background traffic)
#
# Apply order: this is part of 00-vpc, applied first.
# ============================================================


# ── DATA SOURCES — FIND ROUTE TABLES BY TAG ─────────────────
# The custom VPC module doesn't output route table IDs, so we look
# them up by the name tag the module assigns automatically.
# These are needed for the S3 Gateway endpoint route table association.

data "aws_vpc" "this" {
  # Read the VPC that the module just created to get its CIDR block.
  # Used for the endpoint security group ingress rule.
  id = module.vpc.vpc_id
}

data "aws_route_table" "private" {
  filter {
    name   = "tag:Name"
    values = ["${var.project_name}-${var.environment}-private"]
  }
  depends_on = [module.vpc]
}

data "aws_route_table" "database" {
  filter {
    name   = "tag:Name"
    values = ["${var.project_name}-${var.environment}-database"]
  }
  depends_on = [module.vpc]
}


# ── SECURITY GROUP — FOR INTERFACE ENDPOINTS ─────────────────
# Interface endpoints live inside your VPC as network interfaces.
# They need a security group that allows HTTPS (443) traffic from
# within the VPC — so EKS nodes can connect to the endpoint.
#
# Only HTTPS port 443: AWS services only accept HTTPS.
# Only from the VPC CIDR: the endpoint is internal-only.
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.project_name}-${var.environment}-vpc-endpoints"
  description = "Allow HTTPS from within VPC to reach AWS service endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTPS from VPC — EKS nodes, pods, and other VPC resources"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.this.cidr_block]  # only traffic from within the VPC
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-vpc-endpoints"
  })
}


# ══════════════════════════════════════════════════════════════
# GATEWAY ENDPOINT — S3 (FREE)
# ══════════════════════════════════════════════════════════════
# S3 is where ECR actually stores your Docker image layers.
# When Kubernetes pulls "expense-backend:abc1234", it:
#   1. Calls ECR API to get the image manifest
#   2. Calls ECR DKR to initiate the pull
#   3. Downloads the actual layer data from S3
#
# Step 3 is the bulk of the data — a 500MB image means 500MB of S3 traffic.
# Without this endpoint, that 500MB goes through NAT at $0.045/GB = $0.023/pull.
# With 100 deployments/month = $2.25 just for ECR layer data.
#
# This endpoint makes that traffic FREE. It adds a route to the private
# route table: "for s3.amazonaws.com, go through the endpoint, not NAT."
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.us-east-1.s3"
  vpc_endpoint_type = "Gateway"

  # Add the S3 route to both private and database route tables.
  # Database subnets are included because RDS can also benefit from
  # S3 access (e.g., automated backups, enhanced monitoring).
  route_table_ids = [
    data.aws_route_table.private.id,
    data.aws_route_table.database.id,
  ]

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-s3-endpoint"
  })
}


# ══════════════════════════════════════════════════════════════
# INTERFACE ENDPOINTS — ECR
# ══════════════════════════════════════════════════════════════
# Two endpoints are needed for full ECR functionality:
#
#   ecr.api — the control plane (list repositories, get auth tokens)
#   ecr.dkr — the data plane (docker push, docker pull manifest)
#
# Together with the S3 gateway endpoint above, ALL ECR traffic
# (auth + manifest + layers) stays on AWS's private network.

# ECR API — authentication and repository management calls
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.us-east-1.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]

  # private_dns_enabled = true is the KEY setting.
  # Without it, the endpoint exists but nothing uses it —
  # DNS still resolves ecr.amazonaws.com to a public IP.
  # With it, DNS resolves to the endpoint's private IP inside your VPC.
  # Existing code (Docker, kubectl, AWS CLI) needs zero changes.
  private_dns_enabled = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-ecr-api-endpoint"
  })
}

# ECR DKR — docker push/pull operations
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.us-east-1.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-ecr-dkr-endpoint"
  })
}


# ══════════════════════════════════════════════════════════════
# INTERFACE ENDPOINTS — SSM SESSION MANAGER
# ══════════════════════════════════════════════════════════════
# SSM Session Manager (our bastion replacement) needs THREE endpoints
# to work correctly. All three must be present — missing any one of
# them causes Session Manager to fall back through NAT or fail entirely.
#
#   ssm        — SSM API calls (parameter store, run command, etc.)
#   ssmmessages — the WebSocket channel for interactive shell sessions
#   ec2messages — the SSM agent's heartbeat and command delivery channel
#
# Without these, every `aws ssm start-session` command and every character
# you type in a shell session goes through NAT Gateway at $0.045/GB.
# With endpoints: those keystrokes and output travel over AWS's backbone for free.

resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.us-east-1.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-ssm-endpoint"
  })
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.us-east-1.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-ssmmessages-endpoint"
  })
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.us-east-1.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-ec2messages-endpoint"
  })
}


# ══════════════════════════════════════════════════════════════
# INTERFACE ENDPOINT — CLOUDWATCH LOGS
# ══════════════════════════════════════════════════════════════
# Fluent Bit runs on every EKS node and continuously ships pod logs
# to CloudWatch Logs. Without this endpoint, every log batch —
# flushed every 5 seconds from every node — goes through NAT.
#
# A busy app pod might log 1MB/minute per node.
# 2 nodes × 1MB/min × 60min × 24h × 30 days = ~86GB/month.
# At $0.045/GB: ~$3.90/month in NAT charges just for logs.
# The endpoint pays for itself if log volume is this high.
resource "aws_vpc_endpoint" "cloudwatch_logs" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.us-east-1.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-cloudwatch-logs-endpoint"
  })
}


# ── OUTPUTS — DOCUMENT WHAT WAS CREATED ──────────────────────
output "vpc_endpoints_summary" {
  description = "VPC endpoints created — all AWS service traffic stays on AWS private network"
  value = {
    s3_gateway    = aws_vpc_endpoint.s3.id              # FREE — docker layer data
    ecr_api       = aws_vpc_endpoint.ecr_api.id         # ECR auth + API
    ecr_dkr       = aws_vpc_endpoint.ecr_dkr.id         # docker push/pull
    ssm           = aws_vpc_endpoint.ssm.id             # SSM API
    ssmmessages   = aws_vpc_endpoint.ssmmessages.id     # SSM sessions
    ec2messages   = aws_vpc_endpoint.ec2messages.id     # SSM agent
    cloudwatch_logs = aws_vpc_endpoint.cloudwatch_logs.id  # Fluent Bit logs
  }
}
