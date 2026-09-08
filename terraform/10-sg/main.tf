locals {
  vpc_id = data.aws_ssm_parameter.vpc_id.value
}

# --- DB Security Group ---
resource "aws_security_group" "db" {
  name        = "${var.project_name}-${var.environment}-db"
  description = "SG for DB MySQL Instances"
  vpc_id      = local.vpc_id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(var.common_tags, { Name = "${var.project_name}-${var.environment}-db" })
}

# --- Bastion Security Group — REMOVED ---
# The bastion EC2 host has been replaced by AWS Systems Manager Session Manager.
# SSM provides the same shell access with zero open ports and zero EC2 cost.
#
# Before: bastion EC2 + open SSH port → ~$8-15/month + security risk
# After:  SSM Session Manager → $0, no open ports, access via IAM identity
#
# The bastion SG was an empty security group (all its ingress rules were
# already removed when SSM was adopted). Removing the SG itself completes
# the cleanup. If this layer was already applied, run:
#   terraform -chdir=terraform/10-sg state rm aws_security_group.bastion
#   terraform -chdir=terraform/10-sg state rm aws_ssm_parameter.bastion_sg_id
# then re-apply 10-sg to remove the SG from AWS.
#
# See docs/SSM_ACCESS.md for how to connect to EKS nodes via SSM.
}

# --- VPN Security Group ---
resource "aws_security_group" "vpn" {
  name        = "${var.project_name}-${var.environment}-vpn"
  description = "SG for VPN Instances"
  vpc_id      = local.vpc_id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(var.common_tags, { Name = "${var.project_name}-${var.environment}-vpn" })
}

# --- EKS Control Plane Security Group ---
resource "aws_security_group" "cluster" {
  name        = "${var.project_name}-${var.environment}-eks-control-plane"
  description = "SG for EKS Control plane"
  vpc_id      = local.vpc_id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(var.common_tags, { Name = "${var.project_name}-${var.environment}-eks-control-plane" })
}

# --- EKS Node Security Group ---
resource "aws_security_group" "node" {
  name        = "${var.project_name}-${var.environment}-eks-node"
  description = "SG for EKS node"
  vpc_id      = local.vpc_id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(var.common_tags, { Name = "${var.project_name}-${var.environment}-eks-node" })
}

# --- Ingress ALB Security Group ---
resource "aws_security_group" "ingress" {
  name        = "${var.project_name}-${var.environment}-ingress"
  description = "SG for Ingress controller"
  vpc_id      = local.vpc_id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(var.common_tags, { Name = "${var.project_name}-${var.environment}-ingress" })
}

# --- Security Group Rules ---

# REMOVED: bastion_public — SSH :22 was open to 0.0.0.0/0 (the entire internet).
# Replaced by AWS Systems Manager Session Manager: no open ports needed.
# To access EKS nodes: aws ssm start-session --target <instance-id>

# REMOVED: cluster_bastion — EKS cluster no longer accepts connections from Bastion.
# Admin access to the cluster API now goes through IAM + kubectl directly.

resource "aws_security_group_rule" "cluster_node" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "-1"
  source_security_group_id = aws_security_group.node.id
  security_group_id        = aws_security_group.cluster.id
}

resource "aws_security_group_rule" "node_cluster" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "-1"
  source_security_group_id = aws_security_group.cluster.id
  security_group_id        = aws_security_group.node.id
}

resource "aws_security_group_rule" "node_vpc" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "-1"
  cidr_blocks       = ["10.0.0.0/16"]
  security_group_id = aws_security_group.node.id
}

# REMOVED: db_bastion — RDS no longer accepts :3306 from Bastion SG.
# To admin the database, use SSM port forwarding through an EKS node:
#   aws ssm start-session --target <node-id> \
#     --document-name AWS-StartPortForwardingSessionToRemoteHost \
#     --parameters '{"host":["<rds-endpoint>"],"portNumber":["3306"],"localPortNumber":["3306"]}'
# Then connect your local MySQL client to 127.0.0.1:3306

resource "aws_security_group_rule" "db_node" {
  type                     = "ingress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.node.id
  security_group_id        = aws_security_group.db.id
}

resource "aws_security_group_rule" "ingress_public_https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.ingress.id
}

resource "aws_security_group_rule" "ingress_public_http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.ingress.id
}

resource "aws_security_group_rule" "node_ingress" {
  type                     = "ingress"
  from_port                = 30000
  to_port                  = 32768
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ingress.id
  security_group_id        = aws_security_group.node.id
}

resource "aws_security_group_rule" "vpn_rules" {
  count             = length(var.vpn_sg_rules)
  type              = "ingress"
  from_port         = var.vpn_sg_rules[count.index].from_port
  to_port           = var.vpn_sg_rules[count.index].to_port
  protocol          = var.vpn_sg_rules[count.index].protocol
  cidr_blocks       = var.vpn_sg_rules[count.index].cidr_blocks
  security_group_id = aws_security_group.vpn.id
}
