#!/usr/bin/env bash
# Auto-rollback: called by canary-watchdog CronJob or manually via 'make rollback-test'
# Modes:
#   --delete   (default) delete all HTTPRoutes labeled migration=canary
#   --reweight           patch weights: nginx=100, envoy=0 (requires 2 backendRefs)
set -euo pipefail

MODE="${1:---delete}"
LABEL_SELECTOR="migration=canary"
DRY_RUN="${DRY_RUN:-false}"

kubectl_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] kubectl $*"
  else
    kubectl "$@"
  fi
}

echo "=== auto-rollback triggered: mode=$MODE dry_run=$DRY_RUN ==="

ROUTES=$(kubectl get httproute -A -l "$LABEL_SELECTOR" \
  -o custom-columns="NS:.metadata.namespace,NAME:.metadata.name" --no-headers 2>/dev/null || true)

if [[ -z "$ROUTES" ]]; then
  echo "No HTTPRoutes with label '$LABEL_SELECTOR' found — nothing to do."
  exit 0
fi

COUNT=$(echo "$ROUTES" | wc -l | tr -d ' ')
echo "Found $COUNT HTTPRoute(s) to roll back."

if [[ "$MODE" == "--reweight" ]]; then
  # Patch weights: push all traffic back to nginx backend (weight=100), envoy (weight=0)
  # Assumes backendRefs[0]=nginx, backendRefs[1]=envoy — adjust indices if reversed
  PATCH=$(cat <<'EOF'
{"spec":{"rules":[{"backendRefs":[
  {"group":"","kind":"Service","weight":100},
  {"group":"","kind":"Service","weight":0}
]}]}}
EOF
)
  echo "$ROUTES" | while read -r ns name; do
    echo "  reweighting $ns/$name → nginx=100 envoy=0"
    kubectl_cmd patch httproute "$name" -n "$ns" --type=merge -p "$PATCH"
  done

else
  # --delete: remove canary HTTPRoutes entirely; nginx Ingress takes over immediately
  echo "$ROUTES" | while read -r ns name; do
    echo "  deleting $ns/$name"
    kubectl_cmd delete httproute "$name" -n "$ns" --ignore-not-found
  done
fi

echo "=== rollback complete ==="
