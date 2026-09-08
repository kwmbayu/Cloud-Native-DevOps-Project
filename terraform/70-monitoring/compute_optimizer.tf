# ============================================================
# AWS COMPUTE OPTIMIZER — RIGHT-SIZING ANALYSIS (FREE)
#
# WHAT COMPUTE OPTIMIZER DOES:
#   It watches your CloudWatch metrics — CPU, memory, network — for
#   14 days and then tells you: "you're paying for an m7g.large but
#   your app only uses 4% CPU. Here's the instance size you actually need."
#
# ANALOGY:
#   Renting an 18-wheeler to deliver pizzas. You CAN do it, but it's
#   overkill and expensive. Compute Optimizer is the delivery manager
#   who watches your routes for two weeks and says "you need a moped."
#
# COST:
#   Free. Zero cost to enable. No agents to install.
#   It reads the CloudWatch metrics your resources already produce.
#
# WHAT IT ANALYZES:
#   • EC2 instances (including EKS nodes — they're just EC2 under the hood)
#   • EBS volumes attached to those instances
#   • Lambda functions (if any)
#   • ECS services on Fargate (not applicable here)
#   • RDS DB instances (since AWS provider 5.x)
#
# HOW LONG BEFORE RECOMMENDATIONS APPEAR:
#   Compute Optimizer needs at least 30 hours of metric data before
#   it shows any recommendation. For confident, stable recommendations,
#   plan for 14 days of real-world usage under typical load.
#   After 14 days: check the console at
#   https://console.aws.amazon.com/compute-optimizer/
#
# WHAT TO DO WITH THE RECOMMENDATIONS:
#   See docs/RIGHT_SIZING.md for the full playbook — where to look,
#   how to read the confidence score, and which Terraform lines to change.
#
# Apply order: can be applied at any time independently.
# No VPC dependency. No SSM parameters needed.
# ============================================================


# ── COMPUTE OPTIMIZER ENROLLMENT ─────────────────────────────
# This is the entire "enablement" step. One resource, one setting.
# "Active" opts this AWS account in. "Inactive" opts out.
# This is an account-level setting — it applies to all resources
# in account 258464457244 automatically.
#
# Once enrolled:
#   • No CloudWatch alarms or dashboards required
#   • No agents to install on EC2 or EKS nodes
#   • Compute Optimizer reads the standard CloudWatch metrics
#     (CPUUtilization, NetworkIn/Out) that AWS already collects
resource "aws_computeoptimizer_enrollment_status" "this" {
  status = "Active"
  # include_member_accounts: only relevant for AWS Organizations (a root account
  # that manages multiple AWS accounts). For a single-account setup like this
  # project, this field is omitted — the enrollment covers this account only.
}


# ── RIGHT-SIZING UTILIZATION DASHBOARD ───────────────────────
# A CloudWatch dashboard that shows the actual CPU and memory utilization
# of every resource Compute Optimizer is analyzing.
#
# WHY THIS DASHBOARD:
#   You don't have to wait 14 days in the dark. This dashboard lets you
#   see the utilization data RIGHT NOW — and it's the same data Compute
#   Optimizer will base its recommendations on.
#
#   If you see "RDS CPU is 2% on average", that's a strong signal
#   before Compute Optimizer even finishes its analysis.
#
# DASHBOARD LAYOUT:
#   Row 1 — EKS Node CPU:    SPOT nodes (average) | On-Demand node
#   Row 2 — Database:        RDS CPU              | Redis CPU
#   Row 3 — Network:         EKS nodes network in | EKS nodes network out
#
# HOW TO OPEN:
#   AWS Console → CloudWatch → Dashboards → expense-dev-right-sizing
#   Or: https://console.aws.amazon.com/cloudwatch/home#dashboards:
#
# WHAT "RIGHT-SIZED" LOOKS LIKE:
#   CPU average 30-70%   = well-sized (not too big, room for spikes)
#   CPU average 0-10%    = over-provisioned → downsize
#   CPU average 80-100%  = under-provisioned → upsize
resource "aws_cloudwatch_dashboard" "right_sizing" {
  dashboard_name = "${var.project_name}-${var.environment}-right-sizing"

  dashboard_body = jsonencode({
    widgets = [

      # ── TITLE ────────────────────────────────────────────
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = join("\n", [
            "# 📊 Right-Sizing Utilization Dashboard — ${var.project_name}-${var.environment}",
            "",
            "**Purpose:** Monitor actual CPU, memory, and network usage to identify over/under-provisioned resources.",
            "AWS Compute Optimizer analyzes these same metrics and generates right-sizing recommendations after 14 days.",
            "**Well-sized targets:** CPU average 30–70% | Memory 40–80% | Consistently above 80% = upsize | Below 10% = downsize.",
            "",
            "→ [View Compute Optimizer Recommendations](https://console.aws.amazon.com/compute-optimizer/) | [Right-Sizing Playbook](https://github.com/kwmbayu/Cloud-Native-DevOps-Project/blob/master/docs/RIGHT_SIZING.md)"
          ])
        }
      },

      # ── ROW 1: EKS NODE CPU ──────────────────────────────
      # EKS SPOT nodes CPU — average across all SPOT instances
      # Uses a SEARCH expression to find all EC2 instances in the
      # expense-dev EKS cluster without hardcoding instance IDs
      # (SPOT instance IDs change every time a node is replaced).
      {
        type   = "metric"
        x      = 0
        y      = 2
        width  = 12
        height = 6
        properties = {
          title  = "EKS SPOT Nodes — CPU Utilization %"
          region = "us-east-1"
          view   = "timeSeries"
          stacked = false
          period = 300   # 5-minute granularity
          stat   = "Average"
          metrics = [
            # SEARCH finds all EC2 CPUUtilization metrics for instances
            # tagged with this EKS cluster name. SPOT nodes are labeled
            # "green" by EKS (from the node group name).
            [
              { "expression" = "SEARCH('{AWS/EC2,AutoScalingGroupName} MetricName=\"CPUUtilization\" AutoScalingGroupName=\"*${var.project_name}-${var.environment}*green*\"', 'Average', 300)",
                "label"      = "SPOT Node CPU (each line = one node)",
                "id"         = "e1"
              }
            ]
          ]
          annotations = {
            horizontal = [
              { value = 70, label = "Upper target (70%)", color = "#ff7f0e" },
              { value = 10, label = "Lower target (10%) — below = over-provisioned", color = "#2ca02c" }
            ]
          }
        }
      },

      # EKS On-Demand node CPU — the stable safety-net node
      {
        type   = "metric"
        x      = 12
        y      = 2
        width  = 12
        height = 6
        properties = {
          title  = "EKS On-Demand Node — CPU Utilization %"
          region = "us-east-1"
          view   = "timeSeries"
          stacked = false
          period = 300
          stat   = "Average"
          metrics = [
            [
              { "expression" = "SEARCH('{AWS/EC2,AutoScalingGroupName} MetricName=\"CPUUtilization\" AutoScalingGroupName=\"*${var.project_name}-${var.environment}*on*demand*\"', 'Average', 300)",
                "label"      = "On-Demand Node CPU",
                "id"         = "e2"
              }
            ]
          ]
          annotations = {
            horizontal = [
              { value = 70, label = "Upper target", color = "#ff7f0e" },
              { value = 10, label = "Lower target — below = over-provisioned", color = "#2ca02c" }
            ]
          }
        }
      },

      # ── ROW 2: DATABASE TIERS ────────────────────────────
      # RDS CPU — the database instance
      {
        type   = "metric"
        x      = 0
        y      = 8
        width  = 8
        height = 6
        properties = {
          title  = "RDS MySQL — CPU Utilization %"
          region = "us-east-1"
          view   = "timeSeries"
          period = 300
          stat   = "Average"
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", "${var.project_name}-${var.environment}",
             { "label" = "RDS CPU %" }]
          ]
          annotations = {
            horizontal = [
              { value = 70, label = "Upper target", color = "#ff7f0e" },
              { value = 10, label = "Lower — if consistently here, downsize db class", color = "#2ca02c" }
            ]
          }
        }
      },

      # RDS database connections — tracks how many app connections are open
      {
        type   = "metric"
        x      = 8
        y      = 8
        width  = 8
        height = 6
        properties = {
          title  = "RDS — Database Connections"
          region = "us-east-1"
          view   = "timeSeries"
          period = 300
          stat   = "Maximum"
          metrics = [
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", "${var.project_name}-${var.environment}",
             { "label" = "Open connections" }]
          ]
          yAxis = { left = { min = 0 } }
        }
      },

      # Redis CPU — the ElastiCache caching layer
      {
        type   = "metric"
        x      = 16
        y      = 8
        width  = 8
        height = 6
        properties = {
          title  = "ElastiCache Redis — CPU Utilization %"
          region = "us-east-1"
          view   = "timeSeries"
          period = 300
          stat   = "Average"
          metrics = [
            # Note: ElastiCache adds "-0001" suffix to the cluster ID for the node ID
            ["AWS/ElastiCache", "CPUUtilization", "CacheClusterId", "${var.project_name}-${var.environment}-redis-0001",
             { "label" = "Redis CPU %" }]
          ]
          annotations = {
            horizontal = [
              { value = 70, label = "Upper target", color = "#ff7f0e" },
              { value = 10, label = "Lower — if here consistently, t4g.nano may suffice", color = "#2ca02c" }
            ]
          }
        }
      },

      # ── ROW 3: MEMORY AND NETWORK ───────────────────────
      # RDS FreeableMemory — how much RAM is available
      {
        type   = "metric"
        x      = 0
        y      = 14
        width  = 8
        height = 6
        properties = {
          title  = "RDS — Freeable Memory (GB)"
          region = "us-east-1"
          view   = "timeSeries"
          period = 300
          stat   = "Average"
          metrics = [
            [
              { "expression" = "m1 / 1073741824",
                "label"      = "Free Memory (GB)",
                "id"         = "e3"
              }
            ],
            ["AWS/RDS", "FreeableMemory", "DBInstanceIdentifier", "${var.project_name}-${var.environment}",
             { "id" = "m1", "visible" = false }]
          ]
          yAxis = { left = { min = 0, label = "GB" } }
        }
      },

      # EKS nodes — Network In (data received by nodes = requests in)
      {
        type   = "metric"
        x      = 8
        y      = 14
        width  = 8
        height = 6
        properties = {
          title  = "EKS Nodes — Network In (bytes/5min)"
          region = "us-east-1"
          view   = "timeSeries"
          period = 300
          stat   = "Sum"
          metrics = [
            [
              { "expression" = "SEARCH('{AWS/EC2,AutoScalingGroupName} MetricName=\"NetworkIn\" AutoScalingGroupName=\"*${var.project_name}-${var.environment}*\"', 'Sum', 300)",
                "label"      = "Network In",
                "id"         = "e4"
              }
            ]
          ]
          yAxis = { left = { min = 0 } }
        }
      },

      # EKS nodes — Network Out (data sent by nodes = responses out)
      {
        type   = "metric"
        x      = 16
        y      = 14
        width  = 8
        height = 6
        properties = {
          title  = "EKS Nodes — Network Out (bytes/5min)"
          region = "us-east-1"
          view   = "timeSeries"
          period = 300
          stat   = "Sum"
          metrics = [
            [
              { "expression" = "SEARCH('{AWS/EC2,AutoScalingGroupName} MetricName=\"NetworkOut\" AutoScalingGroupName=\"*${var.project_name}-${var.environment}*\"', 'Sum', 300)",
                "label"      = "Network Out",
                "id"         = "e5"
              }
            ]
          ]
          yAxis = { left = { min = 0 } }
        }
      }

    ]
  })

  tags = var.common_tags
}


# ── OUTPUTS ──────────────────────────────────────────────────
output "compute_optimizer_status" {
  description = "Compute Optimizer enrollment — recommendations appear after 14 days of usage data"
  value = {
    status          = "Active"
    account_id      = "258464457244"
    dashboard_url   = "https://us-east-1.console.aws.amazon.com/cloudwatch/home#dashboards:name=${var.project_name}-${var.environment}-right-sizing"
    optimizer_url   = "https://console.aws.amazon.com/compute-optimizer/"
    recommendation_eta = "14 days from first resource launch"
    analyzes = [
      "EC2 instances (EKS Graviton SPOT + On-Demand nodes)",
      "EBS volumes attached to EKS nodes",
      "RDS db.t3.micro MySQL instance",
    ]
  }
}
