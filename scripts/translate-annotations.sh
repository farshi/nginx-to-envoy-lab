#!/usr/bin/env bash
# translate-annotations.sh
# Phase-0 tool: audit nginx Ingress annotations and emit Envoy Gateway CRD stubs.
# Output goes to manifests/generated/ — review before applying.
#
# Requires: kubectl, jq
# Optional: ingress2gateway (sigs.k8s.io/ingress2gateway) for full HTTPRoute generation
set -euo pipefail

OUT="manifests/generated"
mkdir -p "$OUT"

echo "=== Phase-0 annotation audit ==="

# ── 1. Full annotation inventory ──────────────────────────────────────────────
echo ""
echo "All annotations in use across all Ingresses:"
echo "─────────────────────────────────────────────"
kubectl get ing -A -o json | \
  jq -r '.items[] |
    .metadata.namespace + "/" + .metadata.name + " | " +
    (.metadata.annotations // {} | keys | join(", "))' | \
  sort | column -t -s'|'

# ── 2. Unknown / hard-to-translate annotations ────────────────────────────────
echo ""
echo "Hard-to-translate annotations (require manual work):"
echo "─────────────────────────────────────────────────────"
kubectl get ing -A -o json | \
  jq -r '.items[] |
    .metadata.namespace + "/" + .metadata.name as $id |
    (.metadata.annotations // {}) | to_entries[] |
    select(.key | test("snippet|modsecurity|lua|server-alias|session-cookie-samesite")) |
    $id + " | " + .key' | \
  sort || echo "(none found)"

# ── 3. Generate HTTPRoutes via ingress2gateway (if installed) ─────────────────
echo ""
if command -v ingress2gateway >/dev/null 2>&1; then
  echo "ingress2gateway found — generating HTTPRoutes..."
  ingress2gateway print \
    --providers=ingress-nginx \
    --all-namespaces \
    > "$OUT/httproutes.yaml"
  ROUTE_COUNT=$(grep -c "^kind: HTTPRoute" "$OUT/httproutes.yaml" || echo 0)
  echo "  → $OUT/httproutes.yaml  ($ROUTE_COUNT routes)"
else
  echo "ingress2gateway not installed — skipping HTTPRoute generation."
  echo "  Install: go install sigs.k8s.io/ingress2gateway@latest"
  echo "  Or: GOBIN=/usr/local/bin go install sigs.k8s.io/ingress2gateway@latest"
fi

# ── 4. Generate per-Ingress policy stubs ─────────────────────────────────────
echo ""
echo "Generating policy stubs..."
STUB_COUNT=0

kubectl get ing -A -o json | jq -c '.items[]' | while read -r ing; do
  NAME=$(echo "$ing"    | jq -r '.metadata.name')
  NS=$(echo "$ing"      | jq -r '.metadata.namespace')
  ANN=$(echo "$ing"     | jq -r '.metadata.annotations // {}')

  READ_TO=$(echo "$ANN"  | jq -r '."nginx.ingress.kubernetes.io/proxy-read-timeout"    // ""')
  CONN_TO=$(echo "$ANN"  | jq -r '."nginx.ingress.kubernetes.io/proxy-connect-timeout" // ""')
  RETRIES=$(echo "$ANN"  | jq -r '."nginx.ingress.kubernetes.io/proxy-next-upstream-tries" // ""')
  LIMIT_RPS=$(echo "$ANN"| jq -r '."nginx.ingress.kubernetes.io/limit-rps"            // ""')
  REWRITE=$(echo "$ANN"  | jq -r '."nginx.ingress.kubernetes.io/rewrite-target"       // ""')
  SSL_RED=$(echo "$ANN"  | jq -r '."nginx.ingress.kubernetes.io/ssl-redirect"         // ""')
  CORS=$(echo "$ANN"     | jq -r '."nginx.ingress.kubernetes.io/enable-cors"          // ""')
  WHITELIST=$(echo "$ANN"| jq -r '."nginx.ingress.kubernetes.io/whitelist-source-range" // ""')
  AUTH_URL=$(echo "$ANN" | jq -r '."nginx.ingress.kubernetes.io/auth-url"             // ""')
  AFFINITY=$(echo "$ANN" | jq -r '."nginx.ingress.kubernetes.io/affinity"             // ""')
  HASH_BY=$(echo "$ANN"  | jq -r '."nginx.ingress.kubernetes.io/upstream-hash-by"     // ""')

  POLICY_FILE="$OUT/policy-${NS}-${NAME}.yaml"
  NEEDS_BTP=false
  NEEDS_SEC=false

  # ── BackendTrafficPolicy ───────────────────────────────────────────
  BTP_BODY=""

  if [[ -n "$READ_TO" || -n "$CONN_TO" ]]; then
    NEEDS_BTP=true
    BTP_BODY+="  timeout:\n"
    [[ -n "$READ_TO"  ]] && BTP_BODY+="    http:\n      requestTimeout: ${READ_TO}s\n"
    [[ -n "$CONN_TO"  ]] && BTP_BODY+="    tcp:\n      connectTimeout: ${CONN_TO}s\n"
  fi

  if [[ -n "$RETRIES" ]]; then
    NEEDS_BTP=true
    BTP_BODY+="  retry:\n    numRetries: ${RETRIES}\n    retryOn:\n      - gateway-error\n      - retriable-4xx\n"
  fi

  if [[ -n "$LIMIT_RPS" ]]; then
    NEEDS_BTP=true
    BTP_BODY+="  rateLimit:\n    type: Local\n    local:\n      rules:\n      - limit:\n          requests: ${LIMIT_RPS}\n          unit: Second\n"
  fi

  if [[ -n "$AFFINITY" && "$AFFINITY" == "cookie" ]]; then
    NEEDS_BTP=true
    BTP_BODY+="  loadBalancer:\n    type: ConsistentHash\n    consistentHash:\n      type: Cookie\n"
  elif [[ -n "$HASH_BY" ]]; then
    NEEDS_BTP=true
    BTP_BODY+="  loadBalancer:\n    type: ConsistentHash\n    consistentHash:\n      type: Header\n      header:\n        name: ${HASH_BY}\n"
  fi

  if [[ "$NEEDS_BTP" == "true" ]]; then
    printf "apiVersion: gateway.envoyproxy.io/v1alpha1\nkind: BackendTrafficPolicy\nmetadata:\n  name: %s-btp\n  namespace: %s\n  labels:\n    migration: canary\nspec:\n  targetRef:\n    group: gateway.networking.k8s.io\n    kind: HTTPRoute\n    name: %s\n%b---\n" \
      "$NAME" "$NS" "$NAME" "$BTP_BODY" >> "$POLICY_FILE"
  fi

  # ── SecurityPolicy ─────────────────────────────────────────────────
  SEC_BODY=""

  if [[ -n "$AUTH_URL" ]]; then
    NEEDS_SEC=true
    SEC_BODY+="  extAuth:\n    http:\n      backendRef:\n        name: # TODO: auth service name\n        port: 8080\n      headersToBackend: [\"Authorization\", \"Cookie\"]\n"
  fi

  if [[ -n "$WHITELIST" ]]; then
    NEEDS_SEC=true
    # Convert comma-separated CIDRs to YAML list
    IFS=',' read -ra CIDRS <<< "$WHITELIST"
    SEC_BODY+="  ipAllowList:\n    cidrRanges:\n"
    for CIDR in "${CIDRS[@]}"; do
      SEC_BODY+="    - cidr: $(echo "$CIDR" | tr -d ' ')\n"
    done
  fi

  if [[ -n "$CORS" && "$CORS" == "true" ]]; then
    CORS_ORIGIN=$(echo "$ANN" | jq -r '."nginx.ingress.kubernetes.io/cors-allow-origin" // "*"')
    CORS_METHODS=$(echo "$ANN" | jq -r '."nginx.ingress.kubernetes.io/cors-allow-methods" // "GET, PUT, POST, DELETE, PATCH, OPTIONS"')
    # CORS in Envoy Gateway goes on HTTPRoute as a filter — emit a comment instead
    SEC_BODY+="  # CORS: add HTTPRoute filter ResponseHeaderModifier or use a SecurityPolicy CORS extension\n"
    SEC_BODY+="  # cors-allow-origin: ${CORS_ORIGIN}\n"
    SEC_BODY+="  # cors-allow-methods: ${CORS_METHODS}\n"
    NEEDS_SEC=true
  fi

  if [[ "$NEEDS_SEC" == "true" ]]; then
    printf "apiVersion: gateway.envoyproxy.io/v1alpha1\nkind: SecurityPolicy\nmetadata:\n  name: %s-sec\n  namespace: %s\n  labels:\n    migration: canary\nspec:\n  targetRef:\n    group: gateway.networking.k8s.io\n    kind: HTTPRoute\n    name: %s\n%b---\n" \
      "$NAME" "$NS" "$NAME" "$SEC_BODY" >> "$POLICY_FILE"
  fi

  # ── HTTPRoute-level filters (rewrite, ssl-redirect) ───────────────
  if [[ -n "$REWRITE" || -n "$SSL_RED" ]]; then
    FILTER_FILE="$OUT/httproute-filters-${NS}-${NAME}.yaml"
    echo "# HTTPRoute filters for $NS/$NAME — merge these into the HTTPRoute spec" >> "$FILTER_FILE"
    echo "# Generated from nginx annotations — review before applying" >> "$FILTER_FILE"
    echo "" >> "$FILTER_FILE"
    if [[ -n "$REWRITE" ]]; then
      printf "# nginx: rewrite-target: %s\n# Envoy HTTPRoute filter:\n#   filters:\n#   - type: URLRewrite\n#     urlRewrite:\n#       path:\n#         type: ReplacePrefixMatch\n#         replacePrefixMatch: %s\n\n" \
        "$REWRITE" "$REWRITE" >> "$FILTER_FILE"
    fi
    if [[ -n "$SSL_RED" && "$SSL_RED" == "true" ]]; then
      printf "# nginx: ssl-redirect: true\n# Envoy HTTPRoute filter:\n#   filters:\n#   - type: RequestRedirect\n#     requestRedirect:\n#       scheme: https\n#       statusCode: 301\n\n" >> "$FILTER_FILE"
    fi
  fi

  [[ "$NEEDS_BTP" == "true" || "$NEEDS_SEC" == "true" ]] && STUB_COUNT=$((STUB_COUNT + 1)) || true
done

echo "  → $OUT/policy-*.yaml  stubs written"
echo ""
echo "=== Summary ==="
echo "  Review all files in $OUT/ before applying."
echo "  Apply with: kubectl apply -f $OUT/"
echo ""
echo "  Manual work required for:"
kubectl get ing -A -o json | \
  jq -r '.items[] | .metadata.namespace + "/" + .metadata.name as $id |
    (.metadata.annotations // {}) | to_entries[] |
    select(.key | test("snippet|modsecurity")) |
    "  ⚠  " + $id + ": " + .key' || echo "  (none)"
