resource "aws_key_pair" "eks" {
  key_name   = "eks"
  # you can paste the public key directly like this
  #public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL6ONJth+DzeXbU3oGATxjVmoRjPepdl7sBuPzzQT2Nc sivak@BOOK-I6CR3LQ85Q"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBsQf5pDv6L7IKXIyBZ/kaskGvLyBXekzF3TWsw1icTA"
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"
  #cluster_service_ipv4_cidr = var.cluster_service_ipv4_cidr
  cluster_name    = "${var.project_name}-${var.environment}"
  cluster_version = "1.30"
  # it should be false in PROD environments
  cluster_endpoint_public_access = true

  vpc_id                   = local.vpc_id
  subnet_ids               = split(",", local.private_subnet_ids)
  control_plane_subnet_ids = split(",", local.private_subnet_ids)

  create_cluster_security_group = false
  cluster_security_group_id     = local.cluster_sg_id

  create_node_security_group = false
  node_security_group_id     = local.node_sg_id

  # the user which you used to create cluster will get admin access
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    coredns                = {}
    eks-pod-identity-agent = {}
    kube-proxy             = {}
    vpc-cni                = {}
  }

  # ── NODE GROUP DEFAULTS ──────────────────────────────────────
  # Settings shared across all node groups unless overridden.
  #
  # WHY GRAVITON (ARM)?
  #   AWS Graviton processors are ARM-based chips designed by Amazon.
  #   Compared to equivalent Intel/AMD instances:
  #     • 20% cheaper per hour for the same vCPU/RAM
  #     • 60% less energy consumption (same workload, greener footprint)
  #     • Same or better performance for Node.js, containers, and general workloads
  #   Node.js runs natively on ARM64 — no code changes needed.
  #   Docker images must be built for linux/arm64 (see .github/workflows/deploy.yml).
  #
  # instance_types: the list of EC2 instance types EKS can choose from.
  # For SPOT, AWS recommends 5+ instance types — more options means
  # EKS can pull from more SPOT capacity pools, making interruptions rarer.
  #
  # All types here are "large" size on the m or r Graviton family.
  # Same general shape (2-4 vCPU, 8-16GB RAM), different generations and
  # memory ratios — gives maximum SPOT pool diversity while staying on Graviton.
  #
  # Graviton generations:
  #   m6g / r6g — Graviton 2 (2021) — very large SPOT pools
  #   m7g / r7g — Graviton 3 (2022) — good pools, ~15% faster than Graviton 2
  #   m8g        — Graviton 4 (2024) — newest, smaller pools but adds diversity
  eks_managed_node_group_defaults = {
    instance_types = [
      # ── Graviton 2 — largest SPOT pools ──
      "m6g.large",   # Graviton 2: 2vCPU, 8GB  — direct m5.large replacement
      "m6gd.large",  # Graviton 2: 2vCPU, 8GB + NVMe local disk
      "r6g.large",   # Graviton 2: 2vCPU, 16GB — memory-optimized, adds pool diversity
      # ── Graviton 3 — next generation ──
      "m7g.large",   # Graviton 3: 2vCPU, 8GB  — direct m6i.large replacement
      "m7gd.large",  # Graviton 3: 2vCPU, 8GB + NVMe local disk
      "r7g.large",   # Graviton 3: 2vCPU, 16GB — memory-optimized, adds pool diversity
      # ── Graviton 4 — newest generation ──
      "m8g.large",   # Graviton 4: 2vCPU, 8GB  — best performance/price, newest
    ]
  }

  eks_managed_node_groups = {

    # ── GROUP 1: SPOT — THE CHEAP WORKHORSE ────────────────────
    # Runs the application workload (expense backend pods).
    # SPOT instances are unused EC2 capacity AWS sells at 60-70% discount.
    # AWS can reclaim them with 2 minutes notice. Kubernetes handles this
    # gracefully: it reschedules pods to other available nodes before shutdown.
    #
    # Why 2 minimum replicas + PodDisruptionBudget:
    #   We already set minReplicas: 2 on the HPA and minAvailable: 1 on the PDB.
    #   If one SPOT node is reclaimed, the other node keeps the app alive while
    #   Kubernetes launches a replacement node in the background.
    #
    # Why 7 instance types:
    #   Each instance type has its own SPOT capacity pool.
    #   7 pools = 7 chances to find available capacity at any moment.
    #   AWS recommends "diversify and go big" — never rely on one instance type.
    green = {
      min_size     = 2     # always keep at least 2 nodes for redundancy
      max_size     = 10    # HPA can scale up to 10 nodes under heavy load
      desired_size = 2     # start with 2; HPA adjusts from here

      capacity_type = "SPOT"   # 60-70% cheaper than On-Demand

      iam_role_additional_policies = {
        AmazonEBSCSIDriverPolicy          = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
        AmazonElasticFileSystemFullAccess = "arn:aws:iam::aws:policy/AmazonElasticFileSystemFullAccess"
        ElasticLoadBalancingFullAccess    = "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
        AmazonSSMManagedInstanceCore      = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      key_name = aws_key_pair.eks.key_name

      # Label SPOT nodes so we can target them with nodeAffinity rules
      labels = {
        "workload"      = "apps"
        "capacity-type" = "spot"
      }
    }

    # ── GROUP 2: ON-DEMAND — THE STABILITY ANCHOR ──────────────
    # One guaranteed node that AWS can never reclaim.
    # Purpose: ensure the cluster always has somewhere to run critical
    # system pods (CoreDNS, kube-proxy, Fluent Bit) even if every
    # SPOT instance is simultaneously reclaimed.
    #
    # Why t4g.medium (not m7g.large)?
    #   This node is not meant to run app pods — it's a safety net.
    #   t4g.medium (2 vCPU, 4GB RAM) is enough for system overhead.
    #   Keeping it small keeps the On-Demand cost minimal.
    #
    #   t4g = Graviton 2 burstable — the "t" class (like t3) but on ARM.
    #   Same concept as t3.medium but 20% cheaper and 60% less energy.
    #
    # Cost: t4g.medium On-Demand = ~$0.034/hr = ~$25/month (1 node always on)
    #   vs. t3.medium:                            ~$30/month
    #   vs. the alternative: 2 On-Demand m7g.large = ~$190/month
    # Savings vs. all On-Demand: roughly $165/month
    on_demand = {
      min_size     = 1   # always keep exactly 1 On-Demand node running
      max_size     = 2   # allow a second if SPOT is fully unavailable
      desired_size = 1

      capacity_type  = "ON_DEMAND"
      instance_types = ["t4g.medium"]  # Graviton 2: 2vCPU, 4GB — replaces t3.medium

      iam_role_additional_policies = {
        AmazonEBSCSIDriverPolicy          = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
        AmazonElasticFileSystemFullAccess = "arn:aws:iam::aws:policy/AmazonElasticFileSystemFullAccess"
        ElasticLoadBalancingFullAccess    = "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
        AmazonSSMManagedInstanceCore      = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      key_name = aws_key_pair.eks.key_name

      # Label On-Demand nodes — system pods can use nodeAffinity to prefer these
      labels = {
        "workload"      = "system"
        "capacity-type" = "on-demand"
      }
    }

    # blue = { ... }  ← kept commented out for blue-green node rotation if needed
  }

  tags = var.common_tags
}