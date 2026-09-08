# Accessing EKS Nodes & RDS — via SSM Session Manager

## Why SSM instead of a Bastion host?

| | Bastion EC2 | SSM Session Manager |
|---|---|---|
| **Cost** | ~$8–15/month (EC2 running 24/7) | $0 |
| **Ports open** | SSH :22 open to internet | None — zero open ports |
| **Access control** | SSH key file on your laptop | IAM identity (your AWS account) |
| **Audit trail** | None | Every session logged to CloudWatch |
| **Setup** | Maintain EC2, patch OS, manage keys | Nothing to maintain |

The EKS node IAM role already has `AmazonSSMManagedInstanceCore` attached
(in `terraform/40-eks/main.tf`). SSM works on every node out of the box.

---

## One-time setup (your laptop only)

Install the Session Manager plugin — a small CLI tool AWS provides:

```bash
# Mac
brew install --cask session-manager-plugin

# Verify
session-manager-plugin --version
```

Make sure your AWS CLI is configured with credentials that have SSM access:
```bash
aws configure   # or: export AWS_PROFILE=your-profile
aws sts get-caller-identity   # confirm you're authenticated
```

---

## Connect to an EKS node (shell access)

```bash
# Step 1: find a running node's instance ID
aws ec2 describe-instances \
  --filters "Name=tag:eks:cluster-name,Values=expense-dev" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].[InstanceId,PrivateIpAddress]" \
  --output table

# Step 2: open a shell on that node
aws ssm start-session --target i-0abc1234def567890
```

You get a full shell on the node — same as SSH, but no key file needed.
Type `exit` to close the session.

---

## Tunnel to RDS (database admin from your laptop)

SSM can forward a port from your laptop through an EKS node to the RDS
endpoint — like a secure tunnel through the private network.

```bash
# Get the RDS endpoint (after 30-db terraform apply)
RDS_ENDPOINT=$(aws ssm get-parameter \
  --name /expense/dev/db_instance_address \
  --query Parameter.Value --output text 2>/dev/null \
  || terraform -chdir=terraform/30-db output -raw db_instance_address)

# Get an EKS node instance ID
NODE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:eks:cluster-name,Values=expense-dev" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text)

# Open the tunnel: forwards localhost:3306 → node → RDS:3306
aws ssm start-session \
  --target "$NODE_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$RDS_ENDPOINT\"],\"portNumber\":[\"3306\"],\"localPortNumber\":[\"3306\"]}"
```

While that command is running, open a **new terminal** and connect:
```bash
# With mysql client
mysql -h 127.0.0.1 -P 3306 -u expense -p

# With TablePlus / DBeaver / any GUI tool
# Host: 127.0.0.1  Port: 3306  User: expense
```

Press `Ctrl+C` in the first terminal to close the tunnel when done.

---

## Tunnel to Redis (cache inspection from your laptop)

Same pattern — tunnel to the ElastiCache Redis endpoint:

```bash
# Get the Redis endpoint
REDIS_ENDPOINT=$(aws ssm get-parameter \
  --name /expense/dev/redis_host \
  --query Parameter.Value --output text)

# Open the tunnel: forwards localhost:6379 → node → Redis:6379
aws ssm start-session \
  --target "$NODE_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$REDIS_ENDPOINT\"],\"portNumber\":[\"6379\"],\"localPortNumber\":[\"6379\"]}"
```

In a new terminal:
```bash
# Inspect the cache (requires redis-cli: brew install redis)
redis-cli -h 127.0.0.1 -p 6379 ping          # should return PONG
redis-cli -h 127.0.0.1 -p 6379 keys "*"      # list all cached keys
redis-cli -h 127.0.0.1 -p 6379 get "all_transactions"  # read a cached value
redis-cli -h 127.0.0.1 -p 6379 flushall      # clear all cache (forces fresh DB reads)
```

---

## View session history (audit trail)

Every SSM session is automatically logged:

```
AWS Console → Systems Manager → Session Manager → Session history
```

You can see: who connected, when, to which instance, how long the session lasted.
With a Bastion host, this audit trail doesn't exist at all.

---

## IAM permissions needed to use SSM

The IAM user or role connecting needs:
```json
{
  "Effect": "Allow",
  "Action": [
    "ssm:StartSession",
    "ssm:TerminateSession",
    "ssm:DescribeSessions",
    "ec2:DescribeInstances"
  ],
  "Resource": "*"
}
```

Attach this to your personal IAM user in the AWS Console if `start-session` returns "Access Denied".
