# Shadow Traffic Safety — Writes, Mutations, and Side Effects

The default "mirror 100 % of prod traffic to Envoy" in Phase 2 of `ROLLOUT.md` is only safe **if requests have no side effects**. Read-heavy paths (GET search, browse, listing) mirror cleanly. Any path that writes to a database, charges a card, mutates state, or calls a downstream API needs an explicit safety strategy.

This doc covers the strategies and which to pick.

## The problem

```
                ┌─ NGINX ───▶ app ─▶ "INSERT order" ─▶ DB     ✅
mirror 100% ───┤
                └─ ENVOY ───▶ app ─▶ "INSERT order" ─▶ DB     ❌ DUPLICATE
                                                                ❌ stock = -1
                                                                ❌ customer charged twice
```

Same backend serving both = the write happens twice. The mirror response is discarded, but the side effect is not.

## Safety strategies, ranked

### 1 · Mirror only reads (cheapest, fits ~80 % of cases)

Mirror GETs and HEADs, exclude everything else. Most user-facing retail / content traffic is reads.

```yaml
# Envoy HTTPRoute filter — mirror only when method is GET
- match:
    prefix: "/api"
    headers:
      - name: ":method"
        string_match: { exact: "GET" }
  request_mirror_policies:
    - cluster: envoy-shadow
      runtime_fraction: { default_value: { numerator: 100 } }
```

Writes never enter the shadow phase. They start fresh in Phase 3 weighted ramp, typically at 1 % instead of 5 % for extra caution.

**When this works:** the read paths represent the same proxy behaviour the write paths will see — TLS, routing, filters, headers. If the writes use a different codepath inside Envoy (different filter chain, different cluster), this gives weak confidence and you need one of the strategies below.

### 2 · Shadow stack with isolated database (most rigorous)

Two parallel application stacks. Envoy traffic hits its own app instances pointing at a **shadow DB** — a clone refreshed nightly from prod, isolated from prod traffic.

```
                ┌─ NGINX ───▶ app (prod) ──────▶ PROD DB
mirror 100% ───┤
                └─ ENVOY ───▶ app (shadow) ────▶ SHADOW DB (clone)
```

Pros: zero chance of corrupting prod. Full write-path exercised. Same code, isolated state.

Cons: needs provisioning + running a shadow stack and DB. Costs real money. Clone freshness vs storage size is a real trade-off.

When to use: payments, ledger systems, healthcare, anywhere a duplicate write is unacceptable.

### 3 · Shadow-aware app handler (lightweight)

The app detects a header injected by the mirror, runs the handler **but skips the write**.

```python
@app.post("/orders")
def create_order(req):
    body = parse(req)
    new_order = build_order(body)

    if req.headers.get("x-shadow") == "true":
        return jsonify(order_id="shadow", status="dry-run"), 200

    db.insert(new_order)
    return jsonify(order_id=new_order.id, status="created"), 201
```

Envoy's `requestMirrorPolicies` already tags mirrored requests with `x-envoy-internal: true`; add a stable `x-shadow: true` so the app has a single header to gate on.

Pros: same code path tested. Same latency profile. Single DB, no extra infra.

Cons: needs **app code change** at every write site — DB writes, cache writes, S3 puts, downstream API calls, audit log writes. One missed site = corrupted prod state. Code review for the shadow guard becomes a permanent burden.

### 4 · Compare mode (diff the would-be writes)

App captures the *intended* write in memory and emits it as a log/metric, doesn't execute.

```python
if req.headers.get("x-shadow") == "true":
    log_intended_write(new_order)   # ship to OpenSearch / Loki
    return jsonify(status="dry-run"), 200
```

Offline you diff the actual prod writes against the shadow intended writes. If they match, Envoy is producing identical business logic. Catches **semantic** drift — Envoy parses a header differently, header transformation triggers a different downstream branch, etc.

Pros: highest-fidelity test for behavioural equivalence.
Cons: same code-change burden as Strategy 3, plus the offline diff pipeline.

### 5 · Skip mirror entirely for writes — go straight to ramp

For write-heavy or high-stakes endpoints (`/checkout`, `/payments`, `/orders`):

- Phase 2 (mirror) — applies to read endpoints only.
- Phase 3 (ramp) — applies to all endpoints; write endpoints start at **1 %** (not 5 %) and hold longer at each step.

If a single duplicate side-effect is unacceptable and Strategy 2 is too expensive, this is the safe play.

## What this looks like in practice (recipe)

| Endpoint class | Approach |
|---|---|
| GET `/products`, `/search`, `/listings`, `/cart` | **Mirror 100 %** in Phase 2 |
| POST `/cart` (add item, idempotent-ish) | Mirror with shadow header + app dry-run, OR skip mirror + slow ramp |
| POST `/checkout`, `/payment`, `/orders` | **No mirror.** Phase 3 ramp only, 1 to 100 %, longer holds |
| Mutating admin endpoints | No mirror; header-based routing to internal users first |
| Outbound calls to partner APIs | Never mirror; partner contracts treat each call as real |

## Idempotency — the other safety net

Even during the ramp, mutating requests should be idempotent so that **retries don't double-act**. Pattern: client sends `Idempotency-Key: <uuid>` per logical operation. Server stores `(key, result)` for 24 h. Same key arriving twice returns the stored result without re-executing.

If your app doesn't have idempotency keys on mutating endpoints, mirror writes are never safe — and even ramping carries risk because Envoy may retry on connection failure, transparent to the client. Add idempotency keys before the migration starts.

## Decision tree

```
Request type?
│
├─ GET / HEAD ──────────▶ mirror 100% (Strategy 1)
│
├─ POST / PUT / DELETE ─▶ Side effects?
│                          │
│                          ├─ NONE (rare) ──▶ mirror 100%
│                          │
│                          ├─ DB only, app team can change code
│                          │      └─▶ Strategy 3 (shadow-aware handler)
│                          │
│                          ├─ DB + downstream APIs / billing
│                          │      └─▶ Strategy 2 (isolated shadow stack)
│                          │           OR Strategy 5 (skip mirror, slow ramp)
│                          │
│                          └─ Touches money / regulated data
│                                 └─▶ Strategy 5 (no mirror, manual paths, longest hold)
```

## Cross-references

- `ROLLOUT.md` — Phase 2 of the playbook now references this doc when introducing the mirror step.
- `MIGRATION_SUCCESS.md` — the SLO gates apply identically to mirror and ramp phases; what differs is the **blast radius** if a gate breaches.

## One-line summary

> Mirroring writes is only safe if the app distinguishes shadow from real — either via an isolated shadow stack with its own DB, or a header-aware handler that returns a dry-run response without writing. The simplest production-safe approach is: mirror reads, skip mutations, ramp writes carefully with idempotency keys. Payments never shadow.
