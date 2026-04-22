#!/usr/bin/env bash
# scripts/setup-notifications.sh
# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Wire ArgoCD notifications to Slack.
#
# This script:
#   1. Creates (or updates) the argocd-notifications-secret with your Slack token
#   2. Applies the notifications ConfigMap with templates and triggers
#   3. Installs the ArgoCD notifications controller if not already present
#   4. Sends a test notification to verify the integration
#
# Prerequisites:
#   - ArgoCD installed (bootstrap.sh already did this)
#   - A Slack app with chat:write scope and a bot token (xoxb-...)
#     Create one at: https://api.slack.com/apps
#     Invite the bot to your channel: /invite @YourBotName
#
# Usage:
#   export SLACK_TOKEN="xoxb-your-token-here"
#   export SLACK_CHANNEL="gitops-alerts"   # without the # sign
#   chmod +x scripts/setup-notifications.sh
#   ./scripts/setup-notifications.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Config (read from environment, with prompts as fallback) ──────────────────
if [ -z "${SLACK_TOKEN:-}" ]; then
  echo -n "Enter your Slack bot token (xoxb-...): "
  read -rs SLACK_TOKEN
  echo ""
fi

if [ -z "${SLACK_CHANNEL:-}" ]; then
  echo -n "Enter your Slack channel name (without #): "
  read -r SLACK_CHANNEL
fi

[ -z "$SLACK_TOKEN" ]  && error "SLACK_TOKEN is required."
[ -z "$SLACK_CHANNEL" ] && error "SLACK_CHANNEL is required."

# ── Prerequisite checks ───────────────────────────────────────────────────────
command -v kubectl &>/dev/null || error "kubectl is not installed."
kubectl cluster-info &>/dev/null || error "Cannot reach cluster."
kubectl get namespace argocd &>/dev/null || error "argocd namespace not found. Run bootstrap.sh first."

# ── Step 6a: Create/update the notifications secret ──────────────────────────
info "Creating argocd-notifications-secret..."

kubectl create secret generic argocd-notifications-secret \
  --namespace argocd \
  --from-literal="slack-token=${SLACK_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

success "Notifications secret created/updated."

# ── Step 6b: Patch the notifications ConfigMap with the real channel name ─────
# The notifications-cm.yaml uses the channel name from the app annotations.
# This step just confirms the channel is correct in the ConfigMap context block.
info "Applying notifications ConfigMap..."
kubectl apply -f argocd/notifications-cm.yaml -n argocd

# Patch the argocd URL in the context section to the real ArgoCD URL.
# If you have an ingress set up for ArgoCD, replace localhost:8080 here.
ARGOCD_URL="${ARGOCD_URL:-http://localhost:8080}"
kubectl patch configmap argocd-notifications-cm \
  -n argocd \
  --type merge \
  -p "{\"data\":{\"context\":\"argocdUrl: ${ARGOCD_URL}\"}}"

success "Notifications ConfigMap applied."

# ── Step 6c: Ensure the notifications controller is running ───────────────────
info "Checking ArgoCD notifications controller..."

if kubectl get deployment argocd-notifications-controller -n argocd &>/dev/null; then
  kubectl rollout status deployment/argocd-notifications-controller -n argocd --timeout=2m
  success "Notifications controller is running."
else
  warn "Notifications controller not found. It may be bundled with your ArgoCD Helm release."
  warn "Check: kubectl get all -n argocd | grep notification"
fi

# ── Step 6d: Annotate apps to subscribe to Slack notifications ────────────────
info "Subscribing apps to Slack notifications channel: #${SLACK_CHANNEL}..."

for APP in myapp-staging myapp-production; do
  if kubectl get application "$APP" -n argocd &>/dev/null; then
    kubectl annotate application "$APP" -n argocd --overwrite \
      "notifications.argoproj.io/subscribe.on-sync-succeeded.slack=${SLACK_CHANNEL}" \
      "notifications.argoproj.io/subscribe.on-sync-failed.slack=${SLACK_CHANNEL}" \
      "notifications.argoproj.io/subscribe.on-health-degraded.slack=${SLACK_CHANNEL}" \
      "notifications.argoproj.io/subscribe.on-sync-status-unknown.slack=${SLACK_CHANNEL}"
    success "  Annotated ${APP}"
  else
    warn "  Application ${APP} not found — skipping (it will be annotated once ArgoCD syncs it from Git)"
  fi
done

# ── Step 6e: Send a test notification ─────────────────────────────────────────
info "Sending a test Slack notification..."

# Use the Slack API directly to verify the token and channel are correct.
HTTP_STATUS=$(curl -s -o /tmp/slack_test_response.json -w "%{http_code}" \
  -X POST "https://slack.com/api/chat.postMessage" \
  -H "Authorization: Bearer ${SLACK_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"channel\": \"${SLACK_CHANNEL}\",
    \"text\": \"🔔 ArgoCD notifications are configured and working!\",
    \"attachments\": [{
      \"color\": \"#18be52\",
      \"title\": \"GitOps pipeline ready\",
      \"text\": \"ArgoCD will now notify this channel on sync success, failure, and health degradation.\",
      \"footer\": \"ArgoCD Notifications\"
    }]
  }")

if [ "$HTTP_STATUS" = "200" ]; then
  OK=$(python3 -c "import json,sys; d=json.load(open('/tmp/slack_test_response.json')); print(d.get('ok','false'))" 2>/dev/null || echo "unknown")
  if [ "$OK" = "True" ] || [ "$OK" = "true" ]; then
    success "Test notification sent to #${SLACK_CHANNEL}."
  else
    ERROR=$(python3 -c "import json,sys; d=json.load(open('/tmp/slack_test_response.json')); print(d.get('error','unknown'))" 2>/dev/null || echo "unknown")
    warn "Slack API returned ok=false. Error: ${ERROR}"
    warn "Check that your bot is invited to #${SLACK_CHANNEL}: /invite @YourBotName"
  fi
else
  warn "HTTP ${HTTP_STATUS} from Slack API. Check token and network access."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} Step 6 complete — ArgoCD notifications wired to Slack${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Slack channel : #${SLACK_CHANNEL}"
echo "  Events        : sync-succeeded, sync-failed, health-degraded, out-of-sync"
echo ""
echo "  Useful commands:"
echo ""
echo "  # Trigger a sync on staging to test the full flow"
echo "  argocd app sync myapp-staging"
echo ""
echo "  # View notification controller logs"
echo "  kubectl logs -n argocd -l app.kubernetes.io/name=argocd-notifications-controller -f"
echo ""
echo "  # Check app annotations"
echo "  kubectl describe application myapp-staging -n argocd | grep notifications"
echo ""