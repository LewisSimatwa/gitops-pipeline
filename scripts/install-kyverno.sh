# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Install Kyverno and apply all three ClusterPolicies.
#
# Run this after bootstrap.sh has completed and your cluster is healthy.
#
# Usage:
#   chmod +x scripts/install-kyverno.sh
#   ./scripts/install-kyverno.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Prerequisite checks ───────────────────────────────────────────────────────
command -v helm    &>/dev/null || error "helm is not installed."
command -v kubectl &>/dev/null || error "kubectl is not installed."

# Verify cluster access
kubectl cluster-info &>/dev/null || error "Cannot reach cluster. Run: az aks get-credentials ..."

# ── Install Kyverno ───────────────────────────────────────────────────────────
info "Adding Kyverno Helm repo..."
helm repo add kyverno https://kyverno.github.io/kyverno --force-update
helm repo update kyverno

KYVERNO_VERSION="3.1.4"

info "Installing Kyverno ${KYVERNO_VERSION}..."
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --version "${KYVERNO_VERSION}" \
  --values kyverno/kyverno-install.yaml \
  --wait \
  --timeout 5m

success "Kyverno installed."

# ── Wait for Kyverno webhooks to be ready ─────────────────────────────────────
info "Waiting for Kyverno admission controller to be ready..."
kubectl rollout status deployment/kyverno-admission-controller -n kyverno --timeout=3m
kubectl rollout status deployment/kyverno-background-controller -n kyverno --timeout=3m

# ── Apply ClusterPolicies ─────────────────────────────────────────────────────
info "Applying ClusterPolicies..."

# Apply in audit mode first so you can see what would be blocked
# before switching to enforce. Comment this out to go straight to enforce.
info "  → require-resource-limits (Enforce)"
kubectl apply -f kyverno/require-resource-limits.yaml

info "  → require-liveness-probe (Enforce)"
kubectl apply -f kyverno/require-liveness-probe.yaml

info "  → require-non-root (Enforce)"
kubectl apply -f kyverno/require-non-root.yaml

success "All ClusterPolicies applied."

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
info "Active ClusterPolicies:"
kubectl get clusterpolicies

echo ""
info "Checking for existing policy violations across all namespaces..."
# Policy reports are generated asynchronously — wait a moment for them.
sleep 10
kubectl get policyreport -A 2>/dev/null || warn "No policy reports yet (this is normal right after install)."

# ── Test: deploy a non-compliant pod and verify it is blocked ─────────────────
echo ""
info "Running compliance test — attempting to deploy a non-compliant pod..."
BLOCKED=$(kubectl run kyverno-test-pod \
  --image=nginx:latest \
  --namespace=staging \
  --restart=Never \
  --dry-run=server \
  2>&1 || true)

if echo "$BLOCKED" | grep -q "admission webhook"; then
  success "Policy is blocking non-compliant pods as expected."
  echo "  Message: $(echo "$BLOCKED" | grep 'Error' | head -1)"
else
  warn "Non-compliant pod was NOT blocked. Check Kyverno logs:"
  echo "  kubectl logs -n kyverno -l app.kubernetes.io/component=admission-controller --tail=50"
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} Step 5 complete — Kyverno is active${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Useful commands:"
echo ""
echo "  # List all active policies"
echo "  kubectl get clusterpolicies"
echo ""
echo "  # View violations (policy reports)"
echo "  kubectl get policyreport -n staging"
echo "  kubectl get policyreport -n production"
echo ""
echo "  # Describe a specific policy"
echo "  kubectl describe clusterpolicy require-resource-limits"
echo ""
echo "  # View Kyverno admission logs"
echo "  kubectl logs -n kyverno -l app.kubernetes.io/component=admission-controller -f"
echo ""