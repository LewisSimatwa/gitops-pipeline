#!/usr/bin/env bash
# scripts/teardown.sh
# ─────────────────────────────────────────────────────────────────────────────
# Destroys all Azure resources created by this project.
# Run this when you're done working to avoid ongoing charges (~$35/month).
#
# Usage:
#   chmod +x scripts/teardown.sh
#   ./scripts/teardown.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

warn "This will DESTROY all Azure resources created by this project."
warn "Type 'destroy' to confirm or anything else to abort:"
read -r CONFIRM
[ "$CONFIRM" = "destroy" ] || { info "Aborted."; exit 0; }

[ -f terraform/terraform.tfvars ] || error "terraform/terraform.tfvars not found."

cd terraform

info "Running terraform destroy..."
terraform destroy \
  -var="subscription_id=$(grep subscription_id terraform.tfvars | awk -F'"' '{print $2}')" \
  -auto-approve

cd ..
success "All Azure resources destroyed."
echo ""
echo "  Your local kubeconfig still points to the deleted cluster."
echo "  Remove it with:"
echo "  kubectl config delete-context <cluster-name>"
echo "  kubectl config delete-cluster <cluster-name>"