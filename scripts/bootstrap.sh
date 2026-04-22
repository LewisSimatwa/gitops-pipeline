#!/usr/bin/env bash
# scripts/bootstrap.sh
# ─────────────────────────────────────────────────────────────────────────────
# One-shot bootstrap script for Steps 1-3 of the GitOps pipeline.
#
# Run this after filling in terraform/terraform.tfvars.
# It handles Terraform, ArgoCD install, AppProject, and root App-of-Apps
# in the correct dependency order.
#
# Usage:
#   chmod +x scripts/bootstrap.sh
#   ./scripts/bootstrap.sh
#
# Prerequisites (must be installed and on PATH):
#   az        — Azure CLI, logged in:   az login
#   terraform — v1.5+
#   kubectl   — any recent version
#   helm      — v3.12+
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Colours for readable output ───────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Prerequisite checks ───────────────────────────────────────────────────────
info "Checking prerequisites..."
for cmd in az terraform kubectl helm; do
  command -v "$cmd" &>/dev/null || error "$cmd is not installed or not on PATH."
done

# Confirm Azure login
az account show &>/dev/null || error "Not logged in to Azure. Run: az login"
SUBSCRIPTION=$(az account show --query name -o tsv)
info "Azure subscription: ${SUBSCRIPTION}"

# ── Step 1: Terraform ─────────────────────────────────────────────────────────
echo ""
info "━━━━ STEP 1: Terraform — provisioning AKS + ACR + namespaces ━━━━"

[ -f terraform/terraform.tfvars ] || error "terraform/terraform.tfvars not found. Copy from terraform.tfvars.example and fill in values."

cd terraform

info "Running terraform init..."
terraform init

info "Running terraform plan..."
terraform plan -out=tfplan

echo ""
warn "Review the plan above. Type 'yes' to apply or anything else to abort."
read -r CONFIRM
[ "$CONFIRM" = "yes" ] || error "Aborted by user."

info "Running terraform apply..."
terraform apply tfplan

# Extract outputs for later steps
CLUSTER_NAME=$(terraform output -raw aks_cluster_name)
RESOURCE_GROUP=$(terraform output -raw aks_resource_group)
ACR_LOGIN_SERVER=$(terraform output -raw acr_login_server)
CLIENT_ID=$(terraform output -raw github_actions_client_id)
TENANT_ID=$(terraform output -raw github_actions_tenant_id)

cd ..
success "Terraform complete."

# ── Configure kubectl ─────────────────────────────────────────────────────────
info "Fetching AKS credentials..."
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --overwrite-existing

info "Verifying cluster access..."
kubectl get nodes || error "Cannot reach cluster. Check AKS status in Azure portal."
success "kubectl configured."

# ── Step 2: ArgoCD ────────────────────────────────────────────────────────────
echo ""
info "━━━━ STEP 2: ArgoCD — installing and bootstrapping ━━━━"

info "Waiting for argocd namespace..."
kubectl wait --for=jsonpath='{.status.phase}'=Active namespace/argocd --timeout=60s

info "Installing ArgoCD via Helm..."
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update argo

info "Annotating orphaned ArgoCD secrets for Helm adoption..."
# Adopt all secrets in the argocd namespace that are missing Helm ownership labels
for resource_type in secrets configmaps serviceaccounts; do
  for resource in $(kubectl get $resource_type -n argocd --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); do
    kubectl label $resource_type "$resource" -n argocd app.kubernetes.io/managed-by=Helm --overwrite
    kubectl annotate $resource_type "$resource" -n argocd \
      meta.helm.sh/release-name=argocd \
      meta.helm.sh/release-namespace=argocd \
      --overwrite
  done
done

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version 6.7.14 \
  --set server.extraArgs="{--insecure}" \
  --set configs.params."server\.insecure"=true \
  --wait \
  --timeout 10m

success "ArgoCD installed."

info "Waiting for ArgoCD server to be ready..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=5m

# Retrieve initial admin password
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)
success "ArgoCD admin password retrieved."

# Apply notifications ConfigMap
info "Applying ArgoCD notifications ConfigMap..."
kubectl apply -f argocd/notifications-cm.yaml -n argocd

# ── Step 3: Bootstrap ArgoCD App-of-Apps ─────────────────────────────────────
echo ""
info "━━━━ STEP 3: App-of-Apps — bootstrapping the GitOps root app ━━━━"

info "Applying AppProject..."
kubectl apply -f argocd/projects/gitops-project.yaml -n argocd

info "Applying root App-of-Apps..."
kubectl apply -f argocd/apps/root-app.yaml -n argocd

info "Waiting for child apps to appear (up to 2 min)..."
sleep 30
kubectl get applications -n argocd

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} Bootstrap complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  AKS Cluster     : $CLUSTER_NAME"
echo "  Resource Group  : $RESOURCE_GROUP"
echo "  ACR             : $ACR_LOGIN_SERVER"
echo ""
echo "  ArgoCD UI       : http://localhost:8080  (after port-forward below)"
echo "  ArgoCD user     : admin"
echo "  ArgoCD password : $ARGOCD_PASSWORD"
echo ""
echo "  GitHub Actions secrets to add:"
echo "    AZURE_CLIENT_ID       = $CLIENT_ID"
echo "    AZURE_TENANT_ID       = $TENANT_ID"
echo "    AZURE_SUBSCRIPTION_ID = $(az account show --query id -o tsv)"
echo "    ACR_LOGIN_SERVER      = $ACR_LOGIN_SERVER"
echo ""
echo "  Port-forward ArgoCD:"
echo "    kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo ""
echo "  Next: add the GitHub Actions secrets above, then push a commit"
echo "  to trigger the CI pipeline (Step 4)."
echo ""
