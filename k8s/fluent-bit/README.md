# Fluent Bit — Centralized Logging for EKS

## What this does

Deploys **Fluent Bit** as a Kubernetes DaemonSet. One Fluent Bit pod runs on every
EKS node and ships all pod logs to **AWS CloudWatch Logs** in real time.

**Without this:** To see app errors, you'd SSH into a pod. If the pod crashes, logs are gone.

**With this:** All logs land in CloudWatch → searchable in a browser → retained 30 days → alertable.

---

## How it fits together

```
EKS Node
├── expense-backend pod  → console.log("expense created")
├── expense-frontend pod → console.log("page loaded")
└── fluent-bit pod       → reads /var/log/containers/*.log
                           ↓ adds metadata (pod name, namespace, labels)
                           ↓ ships to CloudWatch
                           
CloudWatch Log Group: /expense/dev/application
├── Log Stream: pod/expense-backend-abc123-xyz
└── Log Stream: pod/expense-frontend-def456-uvw
```

---

## Apply order

**Step 1 — Terraform (70-monitoring)**
```bash
cd terraform/70-monitoring
terraform init
terraform apply
```
Note the output: `fluent_bit_role_arn = "arn:aws:iam::258464457244:role/expense-dev-fluent-bit"`

**Step 2 — Update the ServiceAccount YAML**
```bash
# Get the real role ARN
ROLE_ARN=$(aws ssm get-parameter \
  --name /expense/dev/fluent_bit_role_arn \
  --query Parameter.Value --output text)

# Patch the file
sed -i '' "s|FLUENT_BIT_ROLE_ARN|${ROLE_ARN}|g" k8s/fluent-bit/serviceaccount.yaml
```

**Step 3 — Deploy to EKS**
```bash
# Make sure kubectl is pointed at the right cluster
aws eks update-kubeconfig --region us-east-1 --name expense-dev

# Apply all Fluent Bit manifests in order
kubectl apply -f k8s/fluent-bit/namespace.yaml
kubectl apply -f k8s/fluent-bit/serviceaccount.yaml
kubectl apply -f k8s/fluent-bit/rbac.yaml
kubectl apply -f k8s/fluent-bit/configmap.yaml
kubectl apply -f k8s/fluent-bit/daemonset.yaml

# Verify pods are running (one per EKS node)
kubectl get pods -n logging
```

Expected output:
```
NAME               READY   STATUS    RESTARTS   AGE
fluent-bit-abc12   1/1     Running   0          30s
fluent-bit-def34   1/1     Running   0          30s
```

---

## Verify logs are flowing

```bash
# Check Fluent Bit is healthy
kubectl logs -n logging daemonset/fluent-bit --tail=20

# In AWS Console:
# CloudWatch → Log groups → /expense/dev/application
# You should see log streams named pod/expense-backend-*
```

---

## Troubleshoot

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Pods stuck in `Pending` | Node resources full | Check `kubectl describe pod -n logging` |
| Pods in `CrashLoopBackOff` | Config error or IAM issue | `kubectl logs -n logging <pod>` |
| No logs in CloudWatch | IRSA role ARN wrong | Check serviceaccount.yaml annotation |
| `Access Denied` errors | IAM policy missing | Re-run `terraform apply` in 70-monitoring |
