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
  # instance_types: the list of EC2 instance types EKS can choose from.
  # For SPOT, AWS recommends 5+ instance types — more options means
  # EKS can pull from more SPOT capacity pools, making interruptions rarer.
  #
  # All types here are "large" (2 vCPU, 8GB RAM) — same shape, different
  # hardware generations and manufacturers. Kubernetes doesn't care which
  # physical server it runs on, so we give it as many to choose from as possible.
  eks_managed_node_group_defaults = {
    instance_types = [
      # Intel (x86)
      "m6i.large",   # 6th gen Intel — newest, best price/performance
      "m5.large",    # 5th gen Intel — very common, large SPOT pool
      "m5n.large",   # m5 with enhanced networking
      "m5zn.large",  # m5 with high-frequency CPU
      # AMD (x86 — slightly cheaper than Intel, same performance for Node.js)
      "m6a.large",   # 6th gen AMD — good SPOT availability
      "m5a.large",   # 5th gen AMD — very large SPOT pool
      "m5ad.large",  # m5a with NVMe storage
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
    # Why t3.medium (not m5.large)?
    #   This node is not meant to run app pods — it's a safety net.
    #   t3.medium (2 vCPU, 4GB RAM) is enough for system overhead.
    #   Keeping it small keeps the On-Demand cost minimal.
    #
    # Cost: t3.medium On-Demand = ~$0.042/hr = ~$30/month (1 node always on)
    # vs. the alternative: 2 On-Demand m5.large = ~$140/month
    # Savings vs. all On-Demand: roughly $110/month
    on_demand = {
      min_size     = 1   # always keep exactly 1 On-Demand node running
      max_size     = 2   # allow a second if SPOT is fully unavailable
      desired_size = 1

      capacity_type  = "ON_DEMAND"
      instance_types = ["t3.medium"]   # override defaults — smaller is fine here

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