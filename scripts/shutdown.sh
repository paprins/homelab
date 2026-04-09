#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# K3s Cluster Graceful Shutdown
# Drains, stops k3s, and shuts down each node one at a time.
# Workers are shut down first, the control-plane node last.
#
# Usage: ./shutdown.sh [--skip-shutdown] [--ssh-user USER]
#   --skip-shutdown   Drain and stop k3s but do not power off the nodes
#   --ssh-user USER   SSH user for remote commands (default: current user)
# =============================================================================

SKIP_SHUTDOWN=false
SSH_USER="${USER}"
SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "\n${CYAN}===${NC} $1 ${CYAN}===${NC}"; }

confirm() {
  read -r -p "$1 [y/N] " response
  [[ "$response" =~ ^[Yy]$ ]] || error "Aborted."
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-shutdown) SKIP_SHUTDOWN=true; shift ;;
    --ssh-user)      SSH_USER="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--skip-shutdown] [--ssh-user USER]"
      echo "  --skip-shutdown   Drain and stop k3s but do not power off"
      echo "  --ssh-user USER   SSH user (default: \$USER)"
      exit 0
      ;;
    *) error "Unknown option: $1" ;;
  esac
done

# Preflight
command -v kubectl &>/dev/null || error "kubectl not found"
kubectl cluster-info &>/dev/null || error "Cannot reach cluster"

# Discover nodes: workers first, control-plane last
CONTROL_PLANE=""
WORKERS=()

while IFS= read -r line; do
  node=$(echo "$line" | awk '{print $1}')
  roles=$(echo "$line" | awk '{print $3}')
  if [[ "$roles" == *"control-plane"* ]]; then
    CONTROL_PLANE="$node"
  else
    WORKERS+=("$node")
  fi
done < <(kubectl get nodes --no-headers 2>/dev/null)

[[ -n "$CONTROL_PLANE" ]] || error "No control-plane node found"

ORDERED_NODES=("${WORKERS[@]}" "$CONTROL_PLANE")

step "Shutdown plan"
log "SSH user: ${SSH_USER}"
log "Skip shutdown: ${SKIP_SHUTDOWN}"
echo ""
log "Order of operations:"
for i in "${!ORDERED_NODES[@]}"; do
  node="${ORDERED_NODES[$i]}"
  label="worker"
  [[ "$node" == "$CONTROL_PLANE" ]] && label="control-plane"
  echo -e "  $((i + 1)). ${node}  (${label})"
done
echo ""

if [[ "$SKIP_SHUTDOWN" == true ]]; then
  confirm "This will drain and stop k3s on each node (no poweroff). Continue?"
else
  confirm "This will drain, stop k3s, and SHUT DOWN each node. Continue?"
fi

# Process each node
shutdown_node() {
  local node="$1"
  local label="worker"
  [[ "$node" == "$CONTROL_PLANE" ]] && label="control-plane"

  step "Processing ${node} (${label})"

  # --- Drain ---
  log "Draining ${node}..."
  if ! kubectl drain "$node" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --timeout=120s \
    --grace-period=60 2>&1; then
    warn "Drain reported errors for ${node} (may be expected for daemonsets)"
  fi
  log "Drain complete for ${node}"

  # --- Uncordon before stopping, so the node won't be SchedulingDisabled on next boot ---
  log "Uncordoning ${node} (prevents SchedulingDisabled on reboot)..."
  kubectl uncordon "$node" 2>/dev/null || warn "Could not uncordon ${node} (will need manual uncordon on startup)"

  # --- Stop k3s via SSH ---
  local stop_cmd="k3s-killall.sh"
  [[ "$label" == "control-plane" ]] && stop_cmd="k3s-killall.sh"

  log "Stopping k3s on ${node}..."
  # shellcheck disable=SC2029
  ssh ${SSH_OPTS} "${SSH_USER}@${node}" "sudo ${stop_cmd}" 2>&1 || warn "Failed to stop k3s on ${node}"

  # --- Shutdown ---
  if [[ "$SKIP_SHUTDOWN" == true ]]; then
    log "Skipping shutdown for ${node} (--skip-shutdown)"
  else
    log "Shutting down ${node}..."
    # shellcheck disable=SC2029
    ssh ${SSH_OPTS} "${SSH_USER}@${node}" "sudo shutdown now" 2>&1 || true
    log "${node} shutdown command sent"

    # Wait for the node to go offline (unless it's the last one, where we lose API access)
    if [[ "$node" != "$CONTROL_PLANE" ]]; then
      log "Waiting for ${node} to become NotReady..."
      local attempts=0
      while [[ $attempts -lt 30 ]]; do
        status=$(kubectl get node "$node" --no-headers 2>/dev/null | awk '{print $2}' || echo "Unknown")
        if [[ "$status" == *"NotReady"* ]]; then
          log "${node} is NotReady — confirmed offline"
          break
        fi
        sleep 5
        ((attempts++))
      done
      if [[ $attempts -ge 30 ]]; then
        warn "Timed out waiting for ${node} to go NotReady"
      fi
    fi
  fi

  log "Done with ${node}"
}

for node in "${ORDERED_NODES[@]}"; do
  shutdown_node "$node"
done

echo ""
step "Shutdown sequence complete"
if [[ "$SKIP_SHUTDOWN" == true ]]; then
  log "All nodes drained and k3s stopped. Nodes are still powered on."
else
  log "All nodes have been shut down."
  log "On next boot, nodes should rejoin the cluster automatically."
  log "If any node shows SchedulingDisabled, run: kubectl uncordon <node>"
fi
