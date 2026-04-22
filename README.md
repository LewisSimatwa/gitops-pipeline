# GitOps Multi-Environment Pipeline

AKS · ArgoCD · Helm · Kyverno · GitHub Actions · Terraform

A production-grade GitOps pipeline with multi-environment promotion gates,
policy-as-code enforcement, and Slack notifications.

---

## Architecture

```
GitHub repo (source of truth)
│
├── terraform/          → provisions AKS, ACR, namespaces, OIDC identity
├── helm/myapp/         → Helm chart with per-environment value overrides
├── argocd/apps/        → App-of-Apps manifests (root + staging + production)
├── argocd/projects/    → AppProject RBAC scoping
├── kyverno/            → ClusterPolicies (resource limits, probes, non-root)
└── .github/workflows/  → CI pipeline (build → push → bump tag → PR)

                    ┌──────────────────────────────┐
  git push ──────▶  │  GitHub Actions CI           │
                    │  build → ACR push → tag PR   │
                    └──────────────┬───────────────┘
                                   │ merge PR
                    ┌──────────────▼───────────────┐
                    │  ArgoCD (App-of-Apps)         │
                    │                               │
                    │  staging   → auto-sync ✅     │
                    │  production → manual gate 🔒  │
                    └──────────────────────────────┘
                                   │
                    ┌──────────────▼───────────────┐
                    │  Kyverno admission controller │
                    │  blocks non-compliant pods    │
                    └──────────────────────────────┘
```

---

## Prerequisites

| Tool      | Version | Install |
|-----------|---------|---------|
| Azure CLI | latest  | `brew install azure-cli` |
| Terraform | ≥ 1.5   | `brew install terraform` |
| kubectl   | any     | `brew install kubectl` |
| Helm      | ≥ 3.12  | `brew install helm` |

Login to Azure before starting:

```bash
az login
az account set --subscription <your-subscription-id>
```

---

## Quick Start

### 1 — Configure Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your subscription ID, GitHub org/repo, etc.
```

### 2 — Run the bootstrap script

```bash
chmod +x scripts/bootstrap.sh
./scripts/bootstrap.sh
```

This script runs Terraform, installs ArgoCD via Helm, applies the AppProject,
and bootstraps the root App-of-Apps. At the end it prints the ArgoCD admin
password and the GitHub Actions secrets you need to add.

### 3 — Add GitHub Actions secrets

In your GitHub repo → Settings → Secrets and variables → Actions, add:

| Secret name            | Value (from bootstrap output) |
|------------------------|-------------------------------|
| `AZURE_CLIENT_ID`      | Managed identity client ID    |
| `AZURE_TENANT_ID`      | Azure tenant ID               |
| `AZURE_SUBSCRIPTION_ID`| Your subscription ID          |
| `ACR_LOGIN_SERVER`     | ACR login server URL          |

### 4 — Access ArgoCD

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open http://localhost:8080
# Username: admin
# Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

---

## Deployment Flow

### Staging (automatic)

```
commit to main
    → GitHub Actions builds Docker image
    → pushes to ACR
    → opens PR bumping image.tag in values-staging.yaml
    → PR merged
    → ArgoCD detects diff → auto-syncs staging namespace
    → Kyverno validates pod spec
    → Slack notification: sync succeeded
```

### Production (manual gate)

```
staging verified ✓
    → CI opens PR bumping image.tag in values-prod.yaml
    → human reviews and merges PR
    → ArgoCD shows myapp-production as OutOfSync
    → human triggers sync: argocd app sync myapp-production
        (or via ArgoCD UI → Sync button)
    → Kyverno validates pod spec
    → Slack notification: sync succeeded
```

---

## Kyverno Policies

Three `ClusterPolicy` resources enforce standards on every pod in the
`staging` and `production` namespaces:

| Policy | What it blocks |
|--------|---------------|
| `require-resource-limits` | Pods without CPU + memory limits |
| `require-liveness-probe` | Pods without a liveness probe |
| `require-non-root` | Pods running as root (UID 0) |

Violations are **blocked at admission** — the pod never starts.
The Helm chart's `values.yaml` satisfies all three policies by default.

---

## Cost estimate

| Resource | SKU | Monthly cost |
|----------|-----|-------------|
| AKS nodes (2×) | Standard_B2s | ~$30 |
| ACR | Basic | ~$5 |
| **Total** | | **~$35** |

Tear down when not actively working:

```bash
cd terraform && terraform destroy
```

---

## File Structure

```
gitops-pipeline/
├── .gitignore
├── README.md
├── scripts/
│   └── bootstrap.sh              # one-shot setup script
├── terraform/
│   ├── main.tf                   # AKS, ACR, namespaces, OIDC identity
│   ├── variables.tf
│   ├── outputs.tf
│   ├── terraform.tfvars.example
│   └── modules/aks/
│       └── main.tf               # AKS cluster module
├── argocd/
│   ├── apps/
│   │   ├── root-app.yaml         # App-of-Apps root (bootstrap manually)
│   │   ├── staging-app.yaml      # auto-sync enabled
│   │   └── production-app.yaml   # manual sync gate
│   ├── projects/
│   │   └── gitops-project.yaml   # RBAC scoping
│   └── notifications-cm.yaml     # Slack notification templates
├── helm/myapp/
│   ├── Chart.yaml
│   ├── values.yaml               # base values (Kyverno-compliant defaults)
│   ├── values-staging.yaml       # staging overrides
│   ├── values-prod.yaml          # production overrides
│   └── templates/
│       ├── _helpers.tpl
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── serviceaccount.yaml
│       ├── ingress.yaml
│       ├── hpa.yaml
│       ├── pdb.yaml
│       ├── configmap.yaml
│       └── NOTES.txt
└── kyverno/                      # added in Step 5
    ├── require-resource-limits.yaml
    ├── require-liveness-probe.yaml
    └── require-non-root.yaml
```
