# CI/CD Setup — GitHub Actions

## What this pipeline does

Every time you push code to the `main` branch:

```
Push code to GitHub
        ↓
GitHub Actions starts automatically
        ↓
   ┌─────────────────┐      ┌──────────────────────┐
   │ JOB 1: Build    │ ───▶ │ JOB 2: Deploy        │
   │                 │      │                      │
   │ npm install     │      │ Connect to EKS       │
   │ npm test        │      │ helm upgrade         │
   │ docker build    │      │ Verify pods healthy  │
   │ docker push ECR │      │                      │
   └─────────────────┘      └──────────────────────┘
```

On Pull Requests: only Job 1 runs (no deploy).

---

## One-time setup: add 3 secrets to GitHub

Before the pipeline can run, it needs your AWS credentials.
You store these in GitHub (not in the code) so they're never
visible in the repository.

### Step 1 — Create an IAM user for GitHub Actions

In the AWS Console:
1. Go to **IAM → Users → Create user**
2. Name: `github-actions-expense`
3. Attach these policies:
   - `AmazonEC2ContainerRegistryPowerUser` — allows docker push to ECR
   - `AmazonEKSClusterPolicy` — allows kubectl/helm to talk to EKS
   - Create a custom inline policy for CloudFront + SSM + EKS:
     ```json
     {
       "Version": "2012-10-17",
       "Statement": [
         {
           "Effect": "Allow",
           "Action": ["eks:DescribeCluster"],
           "Resource": "arn:aws:eks:us-east-1:258464457244:cluster/expense-dev"
         },
         {
           "Effect": "Allow",
           "Action": ["ssm:GetParameter"],
           "Resource": "arn:aws:ssm:us-east-1:258464457244:parameter/expense/dev/*"
         },
         {
           "Effect": "Allow",
           "Action": ["cloudfront:CreateInvalidation"],
           "Resource": "arn:aws:cloudfront::258464457244:distribution/*"
         }
       ]
     }
     ```
4. Create an **Access Key** (type: Application running outside AWS)
5. Download the CSV — you'll need the key ID and secret

### Step 2 — Add secrets to GitHub

In your GitHub repository:
1. Go to **Settings → Secrets and variables → Actions**
2. Click **New repository secret** for each of the following:

| Secret name          | Value                                    |
|---------------------|------------------------------------------|
| `AWS_ACCESS_KEY_ID` | From the IAM CSV you downloaded          |
| `AWS_SECRET_ACCESS_KEY` | From the IAM CSV you downloaded      |
| `DB_HOST`           | Your RDS endpoint (after terraform apply)|

### Step 3 — Create a GitHub environment called "dev"

The deploy job uses `environment: dev` which enables:
- A visual deployment history in GitHub
- Optional manual approval gates before deploying

In GitHub: **Settings → Environments → New environment** → name it `dev`

### Step 4 — Create the ECR repository (if it doesn't exist)

```bash
aws ecr create-repository \
  --repository-name expense-backend \
  --region us-east-1
```

---

## How to get the DB_HOST value

After running `terraform apply` in `terraform/30-db`:

```bash
cd terraform/30-db
terraform output db_instance_address
```

Paste that value as the `DB_HOST` secret in GitHub.

---

## Testing the pipeline

1. Make any small change to a file (e.g., add a comment to `index.js`)
2. `git add . && git commit -m "test: trigger CI pipeline"`
3. `git push origin main`
4. Go to GitHub → **Actions** tab — you'll see the pipeline running live
