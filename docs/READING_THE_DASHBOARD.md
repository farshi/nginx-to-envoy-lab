# Reading the Dashboard

A panel-by-panel guide to the `Ingress Migration — nginx vs Envoy` Grafana dashboard. The dashboard is a **decision tool**, not just a viewer — each row maps to a cutover SLO gate, and each panel pair tells you whether to advance, hold, or roll back.

## Layout at a glance

```
┌─ Rate (req/s) ────────────────────────────────────┐
│  nginx  (blue, left)      envoy  (orange, right)  │
├─ Errors (5xx %) ──────────────────────────────────┤
│  nginx  (blue, left)      envoy  (orange, right)  │
├─ Latency (p99) ───────────────────────────────────┤
│  nginx  (blue, left)      envoy  (orange, right)  │
├─ Envoy-specific signals ──────────────────────────┤
│  [xDS] [healthy] [outliers] [CB overflow]         │
└───────────────────────────────────────────────────┘
```

Blue panel = the **baseline**. Orange panel = the **new path**. Same row = same metric. You compare *shapes and magnitudes side-by-side*, not absolute values in isolation.

---

## Row 1 — Rate (req/s)

**What it shows:** total requests per second through each ingress.

| Signal | What healthy looks like | What worried looks like |
|---|---|---|
| Both flat at similar magnitude during shadow | ✅ shapes match | ❌ envoy stays at zero (route misconfigured) or wildly higher (load-gen retry storm) |
| During the ramp, nginx ↓ and envoy ↑ proportionally | ✅ total stays constant | ❌ total drops (requests being lost in the middle) |

**Reading trick:** during shadow phase the **sum** of both panels should be ~2× the user-facing traffic (mirror). During the ramp the sum should equal user-facing traffic. If the sum drops, something is silently dropping requests — pause.

**Actionable:** rate alone never blocks the ramp. Use it to confirm load is reaching both paths in the right proportion before judging the error/latency panels.

---

## Row 2 — Errors (5xx %)

**What it shows:** server-error rate as a fraction of all requests through each ingress.

**Baseline:** the **nginx panel value** is your reference number — capture it for at least 7 days before the migration.

**SLO gate:**
> envoy 5xx % ≤ nginx baseline + **0.1 %**

| Visual | Meaning | Action |
|---|---|---|
| Envoy panel curve sits at or below the nginx panel curve | ✅ within budget | proceed |
| Envoy panel briefly spikes during a config push, then returns | ⚠️ likely xDS reconnect — watch xDS panel | hold one weight step |
| Envoy panel persistently above nginx + 0.1 % for >2 minutes | ❌ SLO breach | **L2 rollback** (revert DNS weight to 0 %) |
| Envoy panel climbing while nginx panel flat | ❌ Envoy-specific failure | rollback + investigate |

**Reading trick:** compare *curves*, not single points. A 0.5 % spike that lasts 5 s after a deploy can be noise; a 0.2 % rise sustained for 5 min is a real regression.

**Pitfalls:**
- A non-zero baseline is normal. Apps return 5xx on legitimate failures. You're comparing **delta**, not absolute.
- During shadow phase, the envoy panel may report errors against requests the user never sent — those are real signals about Envoy's behaviour, but won't impact users yet.

---

## Row 3 — Latency (p99)

**What it shows:** 99th-percentile request latency through each ingress over a rolling 5-min window.

**SLO gate:**
> envoy p99 ≤ nginx p99 × **1.10**

| Visual | Meaning | Action |
|---|---|---|
| Envoy curve roughly tracks the nginx curve, same shape, similar magnitude | ✅ proxy overhead is comparable | proceed |
| Envoy curve sits 5–10 % above nginx, flat | ⚠️ proxy overhead is real but bounded | acceptable if the absolute number is still in SLO |
| Envoy curve >10 % above nginx and rising | ❌ SLO breach | **L1 → L2 rollback** |
| Envoy curve spikes only at the top decile (single bucket bleeds into +Inf) | ⚠️ Histogram bucket boundaries wrong | re-bucket histograms — see INSTRUMENTATION.md |

**Reading trick:** the eye sees the **shape**, not the value. If both curves move together, the workload itself is varying and both proxies are coping equally. If only the envoy curve climbs, the proxy is the cause.

**Where the overhead comes from:**
- TLS termination cost (small, constant).
- Cluster discovery / routing overhead per request (sub-ms when xDS is healthy).
- Active connection-pool work.
- Filters in the HCM chain (ext_authz, lua, wasm) — each one adds a few ms.

If envoy p99 is regressing, suspect (in order): a new filter, an upstream pool exhaustion, an mTLS handshake spike, a slow xDS push triggering reconnects.

---

## Row 4 — Envoy-specific stat panels

These four numbers say whether Envoy itself is healthy. If any one goes red, the rate/error/latency panels are about to react too — they're the **leading indicators**.

### xDS connected

| Value | Colour | Meaning | Action |
|---|---|---|---|
| `1` (UP, green) | ✅ | Envoy has a live gRPC stream to its control plane | normal |
| `0` (DOWN, red) | ❌ | Stream broken. **Traffic still flows on last-known-good config** | do not push config changes; investigate control-plane health |

**Decoupling demo:** kill `argocd-server` or `envoy-gateway` (the controller pod) and this flips to 0 while traffic continues. Power line: *"control plane is for changes, data plane is for traffic — they fail independently."*

### Healthy upstream endpoints

| Value | Meaning | Action |
|---|---|---|
| Matches the demo-api pod count (e.g. 3) | ✅ EDS push correct, all pods passing health checks | proceed |
| Below pod count | ⚠️ some pods being ejected or readiness-probe failing | check pod events + readiness probe definition |
| Zero | ❌ no backends — every request returns 503 (UH flag) | pause ramp, fix upstream before retrying |

**Reading trick:** correlate with `kubectl get pods -n demo`. If endpoints=2 but pods=3, one pod is being ejected — check the outlier panel next.

### Outlier ejections (active)

| Value | Meaning | Action |
|---|---|---|
| `0` (green) | ✅ all upstream pods healthy from Envoy's POV | proceed |
| `>=1` (red) | ❌ Envoy auto-ejected one or more endpoints | identify which pod, why (5xx / latency), fix the workload before ramping further |

Outlier ejection is Envoy's circuit-breaker for **endpoints**, not requests. A flaky pod gets removed from the LB pool, retried after a base interval, removed again if it fails the probe.

### Circuit-breaker overflow (UO/sec)

| Value | Meaning | Action |
|---|---|---|
| `0` (green) | ✅ no requests being fast-failed by cluster CB | proceed |
| `>0` (red) | ❌ requests returning 503 with `UO` response flag — CB tripped | raise `max_connections` / `max_pending_requests` in the cluster, or fix the upstream causing pile-up |

Non-zero overflow during shadow phase tells you the CB defaults are too tight for production load. Tune *before* the user-facing ramp.

---

## What each migration phase looks like

### Phase 1 — Deploy parallel

```
Rate     [ ████ ]   [      ]    nginx serving, envoy idle
Errors   [ ── ]    [      ]
Latency  [ ── ]    [      ]
xDS UP        ✅
```

Envoy panels are flat at zero. Don't panic — there's no traffic on the new path yet.

### Phase 2 — Shadow / mirror

```
Rate     [ ████ ]   [ ████ ]   both serving the same volume
Errors   [ ── ]    [ ──── ]    envoy curve should follow nginx
Latency  [ ── ]    [ ──── ]    same shape, slight offset OK
xDS UP        ✅
healthy        3/3
```

**Exit gate:** envoy curves track nginx curves for 24 h, no SLO breach.

### Phase 3 — Weighted ramp 5 % → 100 %

```
5 % step:
Rate     [ ████ ]   [ █    ]   nginx ~95 %, envoy ~5 %
Errors   [ ── ]    [ ──── ]    envoy still equal or lower
Latency  [ ── ]    [ ──── ]

50 % step:
Rate     [ ██   ]   [ ██   ]   even split
Errors   [ ── ]    [ ──── ]
Latency  [ ── ]    [ ──── ]

100 % step:
Rate     [      ]   [ ████ ]   envoy taking everything
Errors   [      ]   [ ──── ]
Latency  [      ]   [ ──── ]
```

**Per step:** hold for the policy window, confirm all four envoy stat panels are green, confirm error + latency panels are within SLO, then move the weight up.

### Phase 4 — Cutover complete (24 h soak)

Same as the 100 % step, sustained. The nginx panels stay flat at zero; envoy panels stay flat at the previous total. **If anything in the envoy column moves in a bad direction during the soak — roll back.**

### Phase 5 — Decommission

nginx Deployment scaled to zero — its panels vanish from Grafana once the scrape returns no targets. Envoy panels are the production view going forward.

---

## Reading framework — RED + leading indicators

| Layer | Question | Panels |
|---|---|---|
| **Traffic shape** | Is the load reaching both paths in the right proportion? | Rate |
| **Quality (SLO)** | Is Envoy at least as good as nginx? | Errors %, Latency p99 |
| **Cause** | If quality regressed, why? | xDS, healthy endpoints, outliers, CB overflow |

Always read the rows in order: shape → quality → cause. If the quality row is red but cause row is green, the regression is *upstream* (application or backend). If quality and cause are both red, the regression is **inside Envoy** and rollback is the right move.

---

## Anti-patterns ("don't do this")

- **Looking only at the envoy panel** — without the nginx baseline you have nothing to compare against. Always read pairs.
- **Acting on a single 10-second spike** — wait for the 5 m rolling window or two consecutive scrape intervals before declaring SLO breach.
- **Promoting on green panels alone** — green dashboard ≠ done. Cross-check `make demo` curl, check upstream pod logs, check that xDS sync is still 1.
- **Tuning CB limits during a ramp** — change one thing at a time. Tune CB during shadow, not during ramp.

---

## One-line summary

> "The dashboard is structured as RED side-by-side: blue nginx baseline left, orange Envoy right, one row per signal — rate, errors, latency. Below it, four stat panels for Envoy-specific leading indicators: xDS sync, healthy endpoints, outlier ejections, circuit-breaker overflow. Each row maps to an SLO gate; the cutover advances or rolls back on what the panels say, not on what anyone hopes."
