# Rollout & Rollback Playbook

Step-by-step procedure for a real production cutover from ingress-nginx to Envoy Gateway. Designed to be reversible at every step. Pair with `MIGRATION_SUCCESS.md` (the SLO gates) and `WHY_MIGRATE.md` (the case).

## Principles

1. **Parallel stack, never in-place.** Both controllers serve real traffic during the cutover.
2. **Reversible at every step.** DNS TTL low; weighted routing flips back in seconds.
3. **Metric-gated promotion.** No step advances unless every SLO in `MIGRATION_SUCCESS.md` is green.
4. **Same artefact, different path.** The backend Service is unchanged — only the L7 path in front of it changes.
5. **Decommission last, not first.** nginx stays warm for 14 days after 100 % Envoy.

## Phases at a glance

```
┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────────┐  ┌───────────┐
│ 0  Prep  │→ │ 1 Deploy │→ │ 2 Shadow │→ │ 3 Weighted  │→ │ 4 Cutover │
│          │  │ parallel │  │  mirror  │  │   ramp      │  │           │
└──────────┘  └──────────┘  └──────────┘  └─────────────┘  └───────────┘
                                                                  │
                                                                  ▼
                                                          ┌───────────────┐
                                                          │ 5 Decommission│
                                                          │   nginx       │
                                                          └───────────────┘
```

## Phase 0 — Preparation (T −7 days)

- [ ] Document current ingress-nginx config: annotations, custom snippets, TLS sources, rate-limit rules.
- [ ] Build the **Envoy translation matrix**: each nginx annotation → Gateway API filter / Envoy feature.
- [ ] Pre-stage Envoy Gateway in non-prod with the same routes; pass functional tests.
- [ ] Lower **DNS TTL to 60 s** for all hostnames that will move. (TTL cache is the silent killer of fast rollbacks.)
- [ ] Confirm baseline metrics from nginx for at least 7 days: request rate, 5xx %, p99 latency. These become the SLO gates.
- [ ] Comms: announce the change window to app teams and incident channel.

## Phase 1 — Deploy in parallel (T −1 day)

- [ ] Install Envoy Gateway alongside ingress-nginx (different namespace, different LB).
- [ ] Apply `GatewayClass` + `Gateway` + `HTTPRoute` mirroring the active nginx routes.
- [ ] Verify Envoy serves the route via direct curl / port-forward (no public traffic yet).
- [ ] Confirm Prometheus scrapes Envoy proxy `/stats/prometheus` and the side-by-side dashboard is populated.
- [ ] **Exit gate:** Envoy returns the same status / body for a fixed test suite as nginx.

## Phase 2 — Shadow / mirror (24 h, zero blast radius)

- [ ] Mirror 100 % of prod traffic to Envoy using either:
  - the load balancer's traffic-mirroring feature (ALB/NLB target group mirror, GCP LB mirror), or
  - an in-cluster sidecar / ext_proc that duplicates requests.
- [ ] Compare response distributions: status code, latency percentiles, body checksums (where safe).
- [ ] Watch new dashboards: Envoy upstream health, outlier ejections, xDS sync state, memory.
- [ ] **Exit gate:** every SLO in `MIGRATION_SUCCESS.md` green for 24 h; no divergent error or latency pattern.

## Phase 3 — Weighted ramp (T 0)

Use DNS weighted records (Route 53 / Cloud DNS / Akamai) or a CDN traffic-split. Either way, the percentages move *external* traffic between the two ingresses.

| Step | Envoy % | Hold | Auto-rollback trigger |
|---|---|---|---|
| 3a | 5 %   | 30 min | any SLO gate breach |
| 3b | 25 %  | 30 min | any SLO gate breach |
| 3c | 50 %  | 60 min | any SLO gate breach |
| 3d | 100 % | soak 24 h | any SLO gate breach |

At each step:

1. Update DNS weights.
2. Watch the dashboard for the hold window.
3. Trigger automated rollback (next section) if any panel turns red.
4. Promote to next weight only after a clean hold.

## Phase 4 — Cutover (T +1 day)

- [ ] After the 24 h soak at 100 % Envoy with all gates green, mark the cutover **complete**.
- [ ] Keep nginx **warm** (no DNS pointing at it, controller still running) so a fast revert is still possible.

## Phase 5 — Decommission (T +14 days)

- [ ] After 14 clean days, delete `Ingress` objects routed through nginx.
- [ ] `helm uninstall ingress-nginx -n ingress-nginx`.
- [ ] Remove nginx-specific dashboards, alerts, runbooks (or mark archived).
- [ ] Final incident-channel comms: migration complete.

## Rollback playbook

Rollback is a **release requirement, not an emergency manoeuvre**. There are four levels — pick the lightest that fixes the breach.

### L1 — Reduce weight (seconds)
DNS weight back to the previous step. Example: 25 % → 5 %. Use when SLO is breached but Envoy is still partially viable.

### L2 — Full revert (≤60 s with 60 s TTL)
DNS weight Envoy 0 %, nginx 100 %. Use when Envoy is materially worse than baseline.

### L3 — Pin via HTTPRoute (in-cluster)
If DNS is slow to propagate or you control internal clients, temporarily route in-cluster to nginx only by updating the HTTPRoute weights to send 0 to the new backend variant.

### L4 — Disable Envoy listener
`kubectl delete gateway eg -n demo` or scale the Envoy proxy Deployment to 0. Use only when Envoy is actively harmful (panic mode).

### Rollback checklist (verbal)
1. Trigger DNS / weight change.
2. Confirm error rate returns to baseline within 2 minutes.
3. Capture: time of breach, gate that fired, screenshot of dashboard, top 3 hypotheses.
4. Open an incident ticket, write the post-mortem.
5. Do not retry the ramp before the root cause is understood and fixed in non-prod.

## Canary patterns (within Envoy, post-migration)

Once on Envoy / Gateway API, the same machinery handles **app-level canaries**:

```yaml
# 10 % canary of a new app version, native HTTPRoute split
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
spec:
  rules:
    - backendRefs:
        - { name: demo-api,    port: 80, weight: 90 }
        - { name: demo-api-v2, port: 80, weight: 10 }
```

Combine with **Argo Rollouts** (or Flagger) for automated promotion based on Prometheus metrics — the rollout controller pulls the SLO from `MIGRATION_SUCCESS.md`-style gates and advances or rolls back without a human in the loop.

## What "successful migration" actually means

1. 100 % of traffic on Envoy for ≥14 days.
2. No rollback below 100 % during the soak.
3. All SLO gates green for the soak window.
4. nginx Helm release deleted, Ingress objects removed, dashboards archived.

That is the bar. Anything less is not done.
