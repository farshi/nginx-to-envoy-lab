# Why Migrate — nginx Ingress → Envoy

This document is the "case for the migration". It exists so reviewers don't have to ask "why are we doing this at all" — the answer is in one table.

## Trigger summary (2024–2026)

| Trigger | What happened | Why it matters |
|---|---|---|
| **Kubernetes Ingress API frozen** | The `networking.k8s.io/v1 Ingress` resource is in maintenance only. No new features. | All routing innovation (traffic split, mirror, header match, retries, timeouts as first-class fields) is in **Gateway API**. Staying on Ingress = ageing into a frozen contract. |
| **Gateway API GA** | Gateway API reached GA in Kubernetes 1.28 (late 2023) and is now the strategic L7 API for the project. | New ingress controllers (Envoy Gateway, Contour, Cilium, Gloo, NGINX Gateway Fabric) are Gateway-API-first. |
| **ingress-nginx CVE pressure (2025)** | Several high/critical CVEs against `kubernetes/ingress-nginx` admission controller and config-rendering paths ("IngressNightmare" family) — RCE-class issues that forced emergency patching across many production fleets. | Compliance and platform teams flagged ingress-nginx as a "manage hard or replace" component. |
| **ingress-nginx project posture** | The community ingress-nginx project is in maintenance mode, with the path forward signposted as Gateway API + a new generation of controllers. | Long-term support story is weaker than it was. |
| **Static config + reload** | nginx reads a static config file and reloads workers on change. | In a high-churn K8s cluster (HPA, rolling deploys, frequent endpoint changes), reloads cause brief disruption and can drop long-lived connections. Envoy reconciles config live over **xDS** with no restart. |
| **No native circuit breaking / outlier detection** | nginx OSS has no cluster-level circuit breaker; nginx Plus has passive checks only. | Production microservices need cascade-failure protection. Envoy ships circuit breakers (`max_connections`, `max_pending_requests`) and outlier ejection by default. |
| **Limited load balancing** | nginx OSS = round-robin. | AI inference, GPU backends, and uneven request cost need **least-request** or consistent-hash (Maglev / ring-hash). Envoy ships all of these. |
| **Observability gap** | nginx requires extra modules / parsing for structured metrics, traces, access logs. | Envoy emits Prometheus metrics, distributed traces (Zipkin / Jaeger / OTLP), and structured JSON access logs out of the box. |
| **Annotation soup** | ingress-nginx behaviour is driven by ~100 vendor-specific annotations. | Annotations are unvalidated strings, vendor-locked, and don't carry into other controllers. Gateway API replaces them with typed fields and filters. |
| **gRPC and HTTP/2** | nginx requires special configuration for gRPC; HTTP/2 upstream behaviour is limited. | Envoy is natively HTTP/2 and gRPC, which matters for modern service-to-service traffic. |

## nginx vs Envoy — at a glance

| Concern | nginx (OSS Ingress) | Envoy (Gateway API) |
|---|---|---|
| **Config delivery** | Static file + reload | Live xDS gRPC push, zero restart |
| **API** | Frozen `Ingress` + annotations | Active `Gateway` / `HTTPRoute` |
| **Traffic splitting (canary)** | Annotation-only, vendor-specific | First-class `backendRefs` with weights |
| **Header / path / mirror routing** | Limited / annotation | Native filters |
| **Load balancing** | Round-robin | Round-robin, least-request, ring-hash, Maglev, locality-aware |
| **Circuit breaking** | None (OSS) | Cluster-level, fast-fail (`UO` 503) |
| **Outlier detection** | None | Auto-ejection on consecutive 5xx / latency |
| **gRPC** | Special config | Native HTTP/2 + gRPC |
| **mTLS / zero-trust mesh** | DIY | First-class (with control plane like Istio / Envoy Gateway, certs via SDS) |
| **Observability** | Add-ons | Prometheus + tracing + structured logs out of the box |
| **Extensibility** | Lua / njs modules | WASM filters, ext_authz, Lua, native filters |
| **Security posture (2025)** | Multiple high-impact CVEs | Smaller historical CVE surface; faster reconcile via xDS reduces footgun radius |
| **Standardisation direction** | Static, vendor-locked | Aligns with Gateway API + service mesh ecosystem |

## Decision framing

> "ingress-nginx is still widely deployed and not dead — but the Ingress API is frozen, the 2025 CVE pressure proved the project is hard to operate safely, and every modern L7 feature (canary, mirror, mTLS, rich LB, observability) is easier in Envoy + Gateway API. Migration is timing, not novelty."

If a single sentence is needed in a steering deck:

> "We are not migrating because nginx is broken. We are migrating because the future of Kubernetes ingress is Gateway API, and our risk profile (frozen API, CVE exposure, lack of native L7 features) is already higher than it should be."
