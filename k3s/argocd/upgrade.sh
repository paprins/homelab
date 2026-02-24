#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# ArgoCD Upgrade Script
# Usage: ./argocd-upgrade.sh <target-version>
# Example: ./argocd-upgrade.sh v3.3.2
# =============================================================================

TARGET_VERSION="${1:-stable}"
ARGOCD_NAMESPACE="argocd"
BACKUP_DIR="./backup/argocd/$(date +%Y%m%d-%H%M%S)"
MANIFEST_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${TARGET_VERSION}/manifests/install.yaml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

confirm() {
  read -r -p "$1 [y/N] " response
  [[ "$response" =~ ^[Yy]$ ]] || error "Aborted by user."
}

# =============================================================================
# PREFLIGHT CHECKS
# =============================================================================
log "Running preflight checks..."

command -v kubectl &>/dev/null || error "kubectl not found in PATH"
kubectl cluster-info &>/dev/null || error "Cannot reach Kubernetes cluster"
kubectl get namespace "$ARGOCD_NAMESPACE" &>/dev/null || error "Namespace '$ARGOCD_NAMESPACE' not found"

CURRENT_VERSION=$(kubectl -n "$ARGOCD_NAMESPACE" get deployment argocd-server \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | cut -d: -f2 || echo "unknown")

log "Current ArgoCD version : ${CURRENT_VERSION}"
log "Target ArgoCD version  : ${TARGET_VERSION}"
log "Manifest URL           : ${MANIFEST_URL}"
log "Backup directory       : ${BACKUP_DIR}"
echo ""

confirm "Proceed with upgrade?"

# =============================================================================
# STEP 1 — BACKUP
# =============================================================================
log "Creating backup directory: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

log "Backing up ArgoCD Applications..."
kubectl get applications -n "$ARGOCD_NAMESPACE" -o yaml > "$BACKUP_DIR/applications.yaml"
APP_COUNT=$(kubectl get applications -n "$ARGOCD_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
log "  → $APP_COUNT Application(s) backed up"

log "Backing up ArgoCD ApplicationSets..."
kubectl get applicationsets -n "$ARGOCD_NAMESPACE" -o yaml > "$BACKUP_DIR/applicationsets.yaml"
APPSET_COUNT=$(kubectl get applicationsets -n "$ARGOCD_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
log "  → $APPSET_COUNT ApplicationSet(s) backed up"

log "Backing up ArgoCD ConfigMaps..."
for cm in argocd-cm argocd-cmd-params-cm argocd-rbac-cm argocd-tls-certs-cm argocd-ssh-known-hosts-cm argocd-gpg-keys-cm; do
  if kubectl get configmap "$cm" -n "$ARGOCD_NAMESPACE" &>/dev/null; then
    kubectl get configmap "$cm" -n "$ARGOCD_NAMESPACE" -o yaml > "$BACKUP_DIR/cm-${cm}.yaml"
    log "  → $cm backed up"
  else
    warn "  → $cm not found, skipping"
  fi
done

log "Backing up ArgoCD Secrets..."
for secret in argocd-secret argocd-repo-creds; do
  if kubectl get secret "$secret" -n "$ARGOCD_NAMESPACE" &>/dev/null; then
    kubectl get secret "$secret" -n "$ARGOCD_NAMESPACE" -o yaml > "$BACKUP_DIR/secret-${secret}.yaml"
    log "  → $secret backed up"
  fi
done

# Also backup any repo credentials secrets (labelled by ArgoCD)
kubectl get secrets -n "$ARGOCD_NAMESPACE" -l "argocd.argoproj.io/secret-type" -o yaml \
  > "$BACKUP_DIR/repo-secrets.yaml" 2>/dev/null && \
  log "  → repo credential secrets backed up"

log "Backup complete: $BACKUP_DIR"
echo ""

# =============================================================================
# STEP 2 — DOWNLOAD & VERIFY MANIFEST
# =============================================================================
log "Downloading manifest from: $MANIFEST_URL"
MANIFEST_FILE="$BACKUP_DIR/install-${TARGET_VERSION}.yaml"
curl -sSL "$MANIFEST_URL" -o "$MANIFEST_FILE" || error "Failed to download manifest"
log "Manifest saved to: $MANIFEST_FILE"
echo ""

confirm "About to apply the new manifest. Continue?"

# =============================================================================
# STEP 3 — APPLY NEW MANIFEST
# =============================================================================
log "Applying ArgoCD manifest..."
kubectl apply -n "$ARGOCD_NAMESPACE" -f "$MANIFEST_FILE"
echo ""

# =============================================================================
# STEP 4 — RESTORE CONFIGMAPS
# =============================================================================
log "Restoring custom ConfigMaps..."

for cm in argocd-cm argocd-cmd-params-cm argocd-rbac-cm argocd-tls-certs-cm argocd-ssh-known-hosts-cm argocd-gpg-keys-cm; do
  BACKUP_FILE="$BACKUP_DIR/cm-${cm}.yaml"
  if [[ -f "$BACKUP_FILE" ]]; then
    # Strip resourceVersion and uid to avoid conflicts, then apply
    kubectl apply -f <(grep -v '^\s*resourceVersion:' "$BACKUP_FILE" | grep -v '^\s*uid:' | grep -v '^\s*creationTimestamp:') \
      2>/dev/null && log "  → $cm restored" || warn "  → $cm restore failed, check manually"
  fi
done

# =============================================================================
# STEP 5 — RESTART ARGOCD SERVER (pick up new config)
# =============================================================================
log "Restarting ArgoCD server to pick up restored config..."
kubectl rollout restart deployment argocd-server -n "$ARGOCD_NAMESPACE"
kubectl rollout status deployment argocd-server -n "$ARGOCD_NAMESPACE" --timeout=120s
echo ""

# =============================================================================
# STEP 6 — WAIT FOR ALL ARGOCD COMPONENTS
# =============================================================================
log "Waiting for all ArgoCD deployments to be ready..."
for deploy in argocd-server argocd-repo-server argocd-application-controller argocd-applicationset-controller argocd-notifications-controller; do
  if kubectl get deployment "$deploy" -n "$ARGOCD_NAMESPACE" &>/dev/null; then
    log "  → Waiting for $deploy..."
    kubectl rollout status deployment "$deploy" -n "$ARGOCD_NAMESPACE" --timeout=180s \
      && log "  → $deploy ready" || warn "  → $deploy not ready in time, check manually"
  fi
done
echo ""

# =============================================================================
# STEP 7 — RESTORE APPLICATIONS & APPLICATIONSETS
# =============================================================================
log "Restoring Applications..."
if [[ "$APP_COUNT" -gt 0 ]]; then
  # Strip managed-fields and server-side metadata before re-applying
  kubectl apply -f <(
    grep -v '^\s*resourceVersion:' "$BACKUP_DIR/applications.yaml" |
    grep -v '^\s*uid:' |
    grep -v '^\s*creationTimestamp:' |
    grep -v '^\s*generation:' |
    grep -v '  managedFields:' 
  ) && log "  → Applications restored" || warn "  → Some Applications failed to restore, check manually"
else
  warn "  → No Applications to restore"
fi

log "Restoring ApplicationSets..."
if [[ "$APPSET_COUNT" -gt 0 ]]; then
  kubectl apply -f <(
    grep -v '^\s*resourceVersion:' "$BACKUP_DIR/applicationsets.yaml" |
    grep -v '^\s*uid:' |
    grep -v '^\s*creationTimestamp:' |
    grep -v '^\s*generation:' |
    grep -v '  managedFields:'
  ) && log "  → ApplicationSets restored" || warn "  → Some ApplicationSets failed to restore, check manually"
else
  warn "  → No ApplicationSets to restore"
fi

# =============================================================================
# STEP 8 — VERIFY
# =============================================================================
echo ""
log "=== POST-UPGRADE VERIFICATION ==="

NEW_VERSION=$(kubectl -n "$ARGOCD_NAMESPACE" get deployment argocd-server \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | cut -d: -f2 || echo "unknown")
log "New ArgoCD version: $NEW_VERSION"

log "ArgoCD pods:"
kubectl get pods -n "$ARGOCD_NAMESPACE"

echo ""
log "Applications:"
kubectl get applications -n "$ARGOCD_NAMESPACE" 2>/dev/null || warn "No applications found"

echo ""
log "ApplicationSets:"
kubectl get applicationsets -n "$ARGOCD_NAMESPACE" 2>/dev/null || warn "No applicationsets found"

echo ""
log "✅ Upgrade complete. Backup saved to: $BACKUP_DIR"
log "If anything looks wrong, backups are in: $BACKUP_DIR"
