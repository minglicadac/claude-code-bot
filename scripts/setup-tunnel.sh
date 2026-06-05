#!/usr/bin/env bash
# setup-tunnel.sh — one-time setup for Cloudflare Tunnel + ADO Service Hook
#
# Prerequisites:
#   1. Cloudflare account (free) — https://dash.cloudflare.com/sign-up
#   2. cloudflared installed on your host — https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/
#   3. A domain added to Cloudflare (even a free one works)
#   4. .env file with AZURE_DEVOPS_ORG, AZURE_DEVOPS_PROJECT, AZURE_DEVOPS_EXT_PAT set
#
# Usage:
#   ./scripts/setup-tunnel.sh          # interactive, step by step
#   ./scripts/setup-tunnel.sh --tunnel  # only create the Cloudflare tunnel
#   ./scripts/setup-tunnel.sh --webhook # only create ADO service hook subscriptions
set -euo pipefail

# ── Load .env if present ───────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
if [[ -f "$PROJECT_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  source "$PROJECT_DIR/.env"
fi

TUNNEL_NAME="claude-robot"
CONFIG_DIR="$HOME/.cloudflared"

# ── Colors ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ═══════════════════════════════════════════════════════════════════════════
# PART 1: Create Cloudflare Tunnel
# ═══════════════════════════════════════════════════════════════════════════
create_tunnel() {
  info "=== Creating Cloudflare Tunnel ==="

  # Check cloudflared is installed
  if ! command -v cloudflared &>/dev/null; then
    error "cloudflared not found. Install it first:
       Windows:  winget install Cloudflare.cloudflared
       macOS:    brew install cloudflared
       Linux:    https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/"
  fi
  ok "cloudflared found: $(cloudflared --version 2>&1 | head -1)"

  # Login
  info "Logging into Cloudflare (opens browser)..."
  cloudflared tunnel login
  ok "Logged in"

  # Create the tunnel
  info "Creating tunnel '${TUNNEL_NAME}'..."
  if cloudflared tunnel list 2>/dev/null | grep -q "${TUNNEL_NAME}"; then
    warn "Tunnel '${TUNNEL_NAME}' already exists, skipping creation"
  else
    cloudflared tunnel create "${TUNNEL_NAME}"
    ok "Tunnel created"
  fi

  # Get the tunnel UUID
  TUNNEL_ID=$(cloudflared tunnel list 2>/dev/null | grep "${TUNNEL_NAME}" | awk '{print $1}')
  if [[ -z "$TUNNEL_ID" ]]; then
    error "Could not find tunnel ID. Run 'cloudflared tunnel list' to check"
  fi
  ok "Tunnel ID: ${TUNNEL_ID}"
  ok "Static URL: https://${TUNNEL_ID}.cfargotunnel.com"

  # Ask for hostname (subdomain of a domain in their Cloudflare account)
  echo ""
  info "You need to route a hostname to this tunnel."
  info "Pick a subdomain of a domain already in your Cloudflare account."
  info "Example: robot.yourdomain.com"
  echo ""
  read -rp "Enter the hostname (e.g. robot.yourdomain.com): " HOSTNAME

  if [[ -z "$HOSTNAME" ]]; then
    error "Hostname is required"
  fi

  # Route DNS
  info "Creating DNS CNAME: ${HOSTNAME} → ${TUNNEL_ID}.cfargotunnel.com"
  cloudflared tunnel route dns "${TUNNEL_NAME}" "${HOSTNAME}"
  ok "DNS route created: https://${HOSTNAME}"

  # Write config file
  mkdir -p "${CONFIG_DIR}"
  cat > "${CONFIG_DIR}/config.yml" <<EOF
tunnel: ${TUNNEL_NAME}
credentials-file: ${CONFIG_DIR}/${TUNNEL_ID}.json

ingress:
  - hostname: ${HOSTNAME}
    service: http://localhost:8080
  - service: http_status:404
EOF
  ok "Config written to ${CONFIG_DIR}/config.yml"

  # Test the tunnel (foreground, Ctrl+C to stop)
  echo ""
  info "To test the tunnel, run:"
  info "  cloudflared tunnel run ${TUNNEL_NAME}"
  info ""
  info "Or run it in Docker (recommended). See below."

  # Get the tunnel token for Docker
  info "Getting tunnel token for docker-compose..."
  echo ""
  warn "To use with docker-compose, you need the TUNNEL_TOKEN."
  warn "Get it from the Cloudflare dashboard:"
  warn "  1. Go to https://one.dash.cloudflare.com/"
  warn "  2. Networks → Tunnels → ${TUNNEL_NAME}"
  warn "  3. Click the three dots → Configure → Install connector"
  warn "  4. Copy the token from the docker command"
  warn ""
  warn "Then add it to your .env:"
  warn "  CLOUDFLARE_TUNNEL_TOKEN=<paste-token-here>"

  WEBHOOK_URL="https://${HOSTNAME}/webhook"
  ok "Your webhook URL: ${WEBHOOK_URL}"
}

# ═══════════════════════════════════════════════════════════════════════════
# PART 2: Create ADO Service Hook Subscriptions
# ═══════════════════════════════════════════════════════════════════════════
create_webhooks() {
  info "=== Creating Azure DevOps Service Hook Subscriptions ==="

  # Validate env vars
  : "${AZURE_DEVOPS_ORG:?AZURE_DEVOPS_ORG not set (add to .env)}"
  : "${AZURE_DEVOPS_PROJECT:?AZURE_DEVOPS_PROJECT not set (add to .env)}"
  : "${AZURE_DEVOPS_EXT_PAT:?AZURE_DEVOPS_EXT_PAT not set (add to .env)}"

  ADO_BASE="https://dev.azure.com/${AZURE_DEVOPS_ORG}"
  AUTH="-u :${AZURE_DEVOPS_EXT_PAT}"

  # Get project ID
  info "Getting project ID for '${AZURE_DEVOPS_PROJECT}'..."
  PROJECT_ID=$(curl -s ${AUTH} \
    "${ADO_BASE}/_apis/projects/${AZURE_DEVOPS_PROJECT}?api-version=7.0" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || \
    curl -s ${AUTH} \
    "${ADO_BASE}/_apis/projects/${AZURE_DEVOPS_PROJECT}?api-version=7.0" \
    | jq -r '.id')

  if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "null" ]]; then
    error "Could not get project ID. Check AZURE_DEVOPS_ORG, AZURE_DEVOPS_PROJECT, and AZURE_DEVOPS_EXT_PAT"
  fi
  ok "Project ID: ${PROJECT_ID}"

  # Ask for webhook URL
  echo ""
  read -rp "Enter your webhook URL (e.g. https://robot.yourdomain.com/webhook): " WEBHOOK_URL
  if [[ -z "$WEBHOOK_URL" ]]; then
    error "Webhook URL is required"
  fi

  # Event types to subscribe to
  EVENTS=(
    "workitem.commented|Work item commented on"
    "workitem.updated|Work item updated"
    "workitem.created|Work item created"
    "git.pullrequest.created|Pull request created"
    "git.pullrequest.updated|Pull request updated"
    "build.complete|Build completed"
  )

  for EVENT_PAIR in "${EVENTS[@]}"; do
    IFS='|' read -r EVENT_TYPE EVENT_LABEL <<< "$EVENT_PAIR"

    info "Creating subscription: ${EVENT_LABEL}..."

    BODY=$(cat <<EOF
{
  "publisherId": "tfs",
  "eventType": "${EVENT_TYPE}",
  "resourceVersion": "1.0",
  "consumerId": "webHooks",
  "consumerActionId": "httpRequest",
  "publisherInputs": {
    "projectId": "${PROJECT_ID}"
  },
  "consumerInputs": {
    "url": "${WEBHOOK_URL}"
  }
}
EOF
)

    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST ${AUTH} \
      -H "Content-Type: application/json" \
      "${ADO_BASE}/_apis/hooks/subscriptions?api-version=7.0" \
      -d "${BODY}")

    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    BODY_OUT=$(echo "$RESPONSE" | sed '$d')

    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
      SUB_ID=$(echo "$BODY_OUT" | jq -r '.id' 2>/dev/null || echo "unknown")
      ok "✓ ${EVENT_LABEL} → subscription ${SUB_ID}"
    else
      warn "✗ ${EVENT_LABEL} → HTTP ${HTTP_CODE}: $(echo "$BODY_OUT" | jq -r '.message' 2>/dev/null || echo "$BODY_OUT" | head -c 200)"
    fi
  done

  echo ""
  ok "Done! Check your subscriptions at:"
  ok "  ${ADO_BASE}/${AZURE_DEVOPS_PROJECT}/_settings/serviceHooks"
}

# ═══════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════
case "${1:-}" in
  --tunnel)
    create_tunnel
    ;;
  --webhook)
    create_webhooks
    ;;
  *)
    echo "Claude Robot — Cloudflare Tunnel + ADO Webhook Setup"
    echo ""
    echo "Usage:"
    echo "  $0 --tunnel   Create the Cloudflare tunnel"
    echo "  $0 --webhook  Create ADO service hook subscriptions"
    echo ""
    echo "Run --tunnel first, then --webhook."
    ;;
esac
