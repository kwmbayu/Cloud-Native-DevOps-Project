# Right-Sizing Playbook — Using AWS Compute Optimizer

## What is right-sizing?

Your infrastructure has **reserved capacity** — you're paying for a certain amount of CPU and RAM on every instance. Right-sizing means matching that reserved capacity to what your app actually uses.

```
Provisioned (what you pay for):  m7g.large  = 2 vCPU, 8 GB RAM
Actually used (what your app uses): 0.1 vCPU, 0.3 GB RAM

You're paying for 2 vCPU but using 5%.
A t4g.small (2 vCPU, 2 GB) would be plenty and costs ~70% less.
```

---

## Step 1 — Check the dashboard (anytime)

The utilization dashboard shows live data — you don't have to wait 14 days to spot obvious over-provisioning.

**Open:** AWS Console → CloudWatch → Dashboards → `expense-dev-right-sizing`

**Or direct link:**
```
https://us-east-1.console.aws.amazon.com/cloudwatch/home#dashboards:name=expense-dev-right-sizing
```

**What to look for:**

| Metric | Healthy range | Action |
|--------|--------------|--------|
| CPU average | 30–70% | No action needed |
| CPU average < 10% | Under-provisioned | Downsize instance class |
| CPU average > 80% | Over-provisioned | Upsize or add replicas |
| RDS FreeableMemory | > 30% of total | Plenty of headroom |
| Redis CPU < 5% | Extremely low | Consider t4g.nano (~$5.50/month) |

---

## Step 2 — Wait 14 days, then read recommendations

Compute Optimizer needs 14 days of data before it shows recommendations. After that:

**Open:** [https://console.aws.amazon.com/compute-optimizer/](https://console.aws.amazon.com/compute-optimizer/)

You'll see categories:

| Category | What it covers |
|----------|---------------|
| EC2 instances | Your EKS nodes (SPOT group + On-Demand node) |
| EBS volumes | Disks attached to EKS nodes |
| RDS instances | The expense-dev MySQL database |
| Lambda | Not applicable (we don't use Lambda) |

Click any resource to see:
- **Current instance:** what you're running now
- **Recommended instance:** what Compute Optimizer suggests
- **Risk:** Low / Medium / High (how confident it is)
- **Projected monthly savings:** exact dollar amount

---

## Step 3 — Reading the confidence levels

Each recommendation has a risk/confidence indicator:

| Confidence | Meaning | Action |
|------------|---------|--------|
| **Very Low** | Not enough data yet (< 14 days) | Wait longer |
| **Low** | Some data, but usage is variable | Monitor more |
| **Medium** | Consistent pattern seen | Apply recommendation |
| **High** | Very consistent over 14 days | Apply with confidence |

**Rule of thumb:** Only act on Medium or High confidence recommendations.

---

## Step 4 — Applying recommendations in Terraform

### If EKS SPOT node group is over-provisioned

Compute Optimizer recommends a smaller instance family. For example:
- **Current:** `m6g.large` (2 vCPU, 8 GB)
- **Recommendation:** `m6g.medium` (1 vCPU, 4 GB)

**File to change:** `terraform/40-eks/main.tf`

```hcl
# BEFORE — m-class large instances
eks_managed_node_group_defaults = {
  instance_types = [
    "m6g.large",
    "m7g.large",
    "m6gd.large",
    ...
  ]
}

# AFTER — if Compute Optimizer recommends medium class
# Update ALL instance types to the new size class
eks_managed_node_group_defaults = {
  instance_types = [
    "m6g.medium",   # Graviton 2: 1vCPU, 4GB
    "m7g.medium",   # Graviton 3: 1vCPU, 4GB
    "m6gd.medium",  # Graviton 2 + NVMe
    "t4g.large",    # burstable — good if CPU is usually low with occasional spikes
    ...
  ]
}
```

Apply: `terraform apply` in `terraform/40-eks/`

> ⚠️ EKS node replacement: changing instance type triggers a rolling replacement
> of all nodes. EKS drains pods from old nodes before terminating them — no downtime
> if you have at least 2 replicas (which HPA ensures).

---

### If the On-Demand node is over-provisioned

- **Current:** `t4g.medium` (2 vCPU, 4 GB)
- **Recommendation:** `t4g.small` (2 vCPU, 2 GB) — if memory use is consistently < 1 GB

**File to change:** `terraform/40-eks/main.tf`

```hcl
on_demand = {
  ...
  instance_types = ["t4g.small"]  # was t4g.medium — saves ~$12/month
  ...
}
```

---

### If RDS is over-provisioned

Compute Optimizer may recommend a smaller DB instance class.

- **Current:** `db.t3.micro` (2 vCPU, 1 GB RAM) — already the smallest MySQL class
- **If recommendation appears:** compare the DB class to your connection count and query complexity

For dev, `db.t3.micro` is already the smallest available. No downsize possible.
For production, if you upsized to `db.t3.small` or larger, Compute Optimizer
may recommend stepping back down.

**File to change:** `terraform/30-db/main.tf`

```hcl
module "db" {
  ...
  instance_class = "db.t3.small"  # change to the recommended class
  ...
}
```

Apply: `terraform apply -var="db_password=YOUR_PASSWORD"` in `terraform/30-db/`

> ⚠️ RDS instance class change causes ~5-10 minutes of downtime.
> The database reboots to apply the new class. Schedule during low-traffic.
> If multi_az = true (for prod), failover makes the downtime ~60 seconds.

---

### If Redis is over-provisioned

- **Current:** `cache.t4g.micro` (0.5 vCPU, 512 MB RAM)
- **If CPU is < 3% and memory use < 100 MB:** consider `cache.t4g.nano` (0.5 vCPU, 512 MB — same spec, lower burst)

Note: ElastiCache Graviton classes are limited. If `.micro` is already the smallest
available for your Redis version, there's nothing to downsize to.

**File to change:** `terraform/35-redis/main.tf`

```hcl
resource "aws_elasticache_cluster" "redis" {
  ...
  node_type = "cache.t4g.nano"  # was cache.t4g.micro
  ...
}
```

> ⚠️ Changing the ElastiCache node type replaces the cluster (new node, cache cleared).
> The `redisHost` parameter in SSM will update automatically via Terraform.
> Your app will see a cache miss storm after the change — it refills over the next 5 minutes.

---

## Step 5 — Enhanced Infrastructure Metrics (optional, paid)

By default, Compute Optimizer uses 14 days of CloudWatch data.

**Enhanced Infrastructure Metrics** extends this to 93 days — useful if your
traffic has weekly patterns (weekday vs. weekend) that 14 days might miss.

**Cost:** $0.0080 per resource per hour (roughly $5.84/month per EC2 instance)

**How to enable via Terraform** (in `compute_optimizer.tf`):

```hcl
resource "aws_computeoptimizer_recommendation_preferences" "ec2_enhanced" {
  resource_type = "Ec2Instance"
  scope {
    name  = "AccountId"
    value = "258464457244"
  }
  enhanced_infrastructure_metrics = "Active"
}
```

For this dev project: the extra cost ($5-10/month per instance) likely outweighs
the value of more precise recommendations. Enable for production.

---

## Quick reference: instance sizing cheat-sheet

When applying recommendations, use Graviton (ARM) equivalents:

| x86 class | Graviton 2 equiv | Graviton 3 equiv | vCPU | RAM |
|-----------|-----------------|-----------------|------|-----|
| t3.nano   | t4g.nano        | —               | 2    | 0.5 GB |
| t3.micro  | t4g.micro       | —               | 2    | 1 GB |
| t3.small  | t4g.small       | —               | 2    | 2 GB |
| t3.medium | t4g.medium      | —               | 2    | 4 GB |
| m5.large  | m6g.large       | m7g.large       | 2    | 8 GB |
| m5.xlarge | m6g.xlarge      | m7g.xlarge      | 4    | 16 GB |

**Rule:** when applying a right-sizing recommendation for x86 instances,
always pick the Graviton equivalent — same spec, 20% cheaper, 60% less energy.

---

## Calendar reminder

Set a reminder 14 days after your first `terraform apply`:

```
Check: https://console.aws.amazon.com/compute-optimizer/
Action: Apply any Medium or High confidence recommendations to Terraform
```

After applying changes, Compute Optimizer restarts its analysis clock.
New recommendations appear 14 days after the resize.
