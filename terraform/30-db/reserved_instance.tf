# ============================================================
# RDS RESERVED INSTANCE — COMMIT TO SAVE 35%
#
# THE CONCEPT:
#   RDS charges On-Demand pricing by default — you pay per hour,
#   no commitment, cancel anytime. This is great for experimentation
#   because you only pay for what you use.
#
#   But for a production database that runs 24/7/365, On-Demand is
#   the most expensive option. AWS offers a discount if you commit:
#   "I promise I'll run this type of database for at least 1 year."
#
# ANALOGY:
#   On-Demand = paying for a hotel room night by night.
#   Reserved Instance = signing a 12-month apartment lease.
#   If you're definitely staying 12 months, the lease is much cheaper.
#
# COST COMPARISON (db.t3.micro, MySQL 8.0, us-east-1, 1 instance):
#
#   On-Demand:              $0.017/hr  =  $12.41/month = $148.92/year
#   1-yr No Upfront RI:     $0.011/hr  =   $8.03/month =  $96.36/year   ← ~35% cheaper
#   1-yr All Upfront RI:    $87.00 once =  $7.25/month =  $87.00/year   ← ~42% cheaper
#
#   No Upfront  saves: $4.38/month   = $52.56/year  — no cash required upfront
#   All Upfront saves: $5.16/month   = $61.92/year  — pay $87 once to maximize savings
#
# WHAT "NO UPFRONT" MEANS:
#   You pay the discounted hourly rate ($0.011) every hour for 12 months.
#   No money down. You just commit to keeping the database running.
#   Best option when you want savings without spending cash upfront.
#
# HOW IT WORKS IN AWS:
#   1. You purchase a reservation for a specific instance type/region/engine.
#   2. AWS finds matching running instances in your account.
#   3. AWS automatically applies the discounted rate to those instances.
#   4. Your existing database (expense-dev) gets the discount with ZERO changes
#      to its configuration, DNS, or connectivity.
#
# ⚠️  IMPORTANT: THIS IS A PURCHASE, NOT NORMAL INFRASTRUCTURE
#   Most Terraform resources:  apply → creates it, destroy → deletes it.
#   Reserved Instances:        apply → PURCHASES a 1-year commitment.
#                              destroy → removes it from Terraform state ONLY.
#                              AWS still bills you for the remaining term!
#
#   This means:
#   - Once you set enable_reserved_instance = true and apply, you've committed.
#   - You cannot undo it for a refund. (AWS does allow selling RIs on the
#     Marketplace, but that's manual and not guaranteed.)
#   - Run `terraform plan` carefully before `terraform apply`.
#
# WHEN TO ENABLE:
#   ✅ The database has been running stably for at least 1-2 months
#   ✅ You plan to keep the project running for at least 12 months
#   ✅ The instance class is not expected to change (e.g., t3.micro → t3.small)
#   ✅ The project is generating or saving money (not just learning)
#
#   ⛔ Don't enable if:
#      - You're still experimenting (might shut it all down next month)
#      - You expect to resize the database soon (RI is locked to one instance class)
#      - The cost ($8/month) isn't worth the paperwork of the commitment
#
# HOW TO ENABLE:
#   Option A — command line:
#     terraform apply -var="enable_reserved_instance=true"
#
#   Option B — in variables.tf, change the default:
#     variable "enable_reserved_instance" { default = true }
#
#   Then review the plan: it will show "1 to add" for the reservation.
#   Confirm, and AWS purchases it. The discount appears on your next bill.
# ============================================================


# ── VARIABLE: THE SAFETY SWITCH ──────────────────────────────
# Default is FALSE — this never runs unless explicitly enabled.
# Change to true only when you're ready to commit for 1 year.
# See the comments above for the full decision checklist.
#
# Added here (not in variables.tf) so all RI logic stays in one file.
variable "enable_reserved_instance" {
  description = <<-EOT
    Set to true to purchase a 1-year No Upfront Reserved Instance for RDS.
    WARNING: This is a billing commitment. Once applied, AWS charges the
    discounted rate for 12 months regardless of whether you destroy this resource.
    Only enable when the project is stable and expected to run for 12+ months.
    Current savings: ~$4.38/month ($52.56/year) for db.t3.micro MySQL.
  EOT
  type        = bool
  default     = false  # ← safe default: never accidentally purchased
}


# ── DATA SOURCE: FIND THE RIGHT OFFERING ─────────────────────
# AWS has thousands of RI offerings (every combination of instance type,
# term, payment option, engine, region, multi-AZ). Instead of hardcoding
# an offering ID (which could change or vary by region), we look it up
# dynamically based on what our database actually is.
#
# This data source is ALWAYS computed (even when enable_reserved_instance=false),
# but it only reads from AWS — it doesn't purchase anything.
# The actual purchase only happens when count = 1 on the resource below.
data "aws_rds_reserved_instance_offering" "mysql_1yr" {
  # Must match the instance_class in main.tf EXACTLY.
  # If you ever upsize the database (e.g., to db.t3.small), you'd need
  # a new RI for the new class — the old one won't apply.
  db_instance_class = "db.t3.micro"

  # Duration is a NUMBER (seconds), not a string.
  # 31536000 = 60 × 60 × 24 × 365 = exactly 1 year
  # AWS only offers 1-year (31536000) or 3-year (94608000) terms.
  duration = 31536000

  # Must match multi_az setting in main.tf (currently false for dev cost savings)
  multi_az = false

  # Payment options: "No Upfront", "Partial Upfront", "All Upfront"
  # "No Upfront" = no cash required, just the discounted hourly rate.
  # Best for: when you want savings without a cash outlay.
  # Switch to "All Upfront" to maximize savings if you have the $87 available.
  offering_type = "No Upfront"

  # Must match the engine in main.tf
  product_description = "mysql"
}


# ── THE RESERVATION PURCHASE ─────────────────────────────────
# count = 0 means this resource does NOT exist (no purchase, no cost).
# count = 1 means Terraform purchases the reservation on the next apply.
#
# Switching from count=0 to count=1: triggers a PURCHASE → ✅ intentional
# Switching from count=1 to count=0: removes from Terraform state only →
#   ⚠️  AWS continues billing until the 12-month term ends!
resource "aws_rds_reserved_instance" "mysql" {
  count = var.enable_reserved_instance ? 1 : 0

  # The offering ID comes from the data source above.
  # It encodes: db.t3.micro + MySQL + 1yr + No Upfront + us-east-1 + single-AZ
  offering_id = data.aws_rds_reserved_instance_offering.mysql_1yr.offering_id

  # How many instances this reservation covers.
  # 1 = covers the single expense-dev RDS instance.
  # If you later add a read replica, you'd need instance_count = 2.
  instance_count = 1

  tags = merge(var.common_tags, {
    Name        = "${var.project_name}-${var.environment}-mysql-ri"
    Purpose     = "1-year Reserved Instance — 35% savings vs On-Demand"
    Term        = "1-year"
    PaymentType = "No Upfront"
    EnabledDate = "set-when-applied"  # update this when you apply
  })
}


# ── OUTPUT: SHOW THE RESERVATION DETAILS ─────────────────────
# Only outputs when enable_reserved_instance = true
output "rds_reserved_instance" {
  description = "Details of the purchased RDS Reserved Instance (null when disabled)"
  value = var.enable_reserved_instance ? {
    offering_id      = data.aws_rds_reserved_instance_offering.mysql_1yr.offering_id
    instance_class   = "db.t3.micro"
    term             = "1 year"
    payment_type     = "No Upfront"
    monthly_rate     = "$8.03"
    monthly_savings  = "$4.38 vs On-Demand ($12.41/month)"
    annual_savings   = "$52.56"
    reservation_id   = try(aws_rds_reserved_instance.mysql[0].id, "not yet purchased")
    status           = try(aws_rds_reserved_instance.mysql[0].state, "not yet purchased")
  } : {
    status = "Reserved Instance disabled — enable_reserved_instance = false"
    action = "Set enable_reserved_instance=true when project is stable (12+ months planned)"
  }
}
