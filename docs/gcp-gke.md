# GCP GKE — Ingress & Service Mesh Reality

What GKE gives you out of the box, where it differs from EKS and AKS, and how the nginx → Envoy migration looks on Google Cloud.

## What GKE gives you by default

GKE is the most "ingress-aware" of the three managed Kubernetes offerings. Google ships **Envoy under the hood** in several first-party ingress options.

| Default / common feature | What it does |
|---|---|
| **VPC-native (alias IP) networking** | Pods get IPs from a secondary VPC range; first-class integration with GCP load balancers |
| **kube-proxy** | Service routing |
| **CoreDNS / kube-dns** | cluster DNS |
| **GKE Ingress controller** | Builtin — turns `Ingress` objects into **GCP HTTP(S) Load Balancer** rules. Already there. |
| **GKE Gateway controller** | Builtin Gateway-API implementation — `GatewayClass` like `gke-l7-global-external-managed` provisions a global HTTPS LB; **Envoy is the data plane underneath**. |
| **GKE Dataplane V2** (option) | eBPF-based dataplane replacing kube-proxy. Better visibility, network policy via Cilium. |
| **Workload Identity Federation for GKE** | Pods get Google Cloud IAM via short-lived tokens — no service-account keys |
| **Anthos Service Mesh (ASM)** | Google-managed Istio (managed control plane) |
| **Cloud Operations (Stackdriver)** | first-party metrics, logs, traces |
| **Autopilot mode** | fully managed nodes + secure defaults |

## Ingress options on GKE

### Option 1 — GKE Gateway (the modern, Envoy-backed default)

Google's Gateway-API implementation. `GatewayClass`es include:

- `gke-l7-global-external-managed` — global external HTTPS LB
- `gke-l7-regional-external-managed` — regional external
- `gke-l7-rilb` — regional internal
- `gke-td` — Traffic Director-backed

**Envoy is the data plane** for these — you write `Gateway` + `HTTPRoute`, Google runs the proxies.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: { name: demo, namespace: demo }
spec:
  gatewayClassName: gke-l7-global-external-managed
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs: [{ name: demo-cert }]
```

### Option 2 — GKE Ingress (the older `Ingress` resource)

Still supported and widely deployed. Ties you to the frozen `Ingress` API + GCP-specific annotations.

### Option 3 — Envoy Gateway / Istio in-cluster

Used when you need data-plane control that isn't surfaced by GKE Gateway (custom WASM filters, ext_authz, bespoke retry policies, fine-grained mTLS).

### Option 4 — Anthos Service Mesh (ASM)

Google-managed Istio. Best for **multi-cluster east-west mTLS** and per-service policy without running Istiod yourself.

## Migration shape on GKE

```
                Cloud DNS (weighted records, low TTL)
                              │
              ┌───────────────┴────────────────┐
              ▼                                ▼
   GCP HTTP(S) LB (old)               GCP HTTP(S) LB (new)
   GKE Ingress + ingress-nginx        GKE Gateway (Envoy data plane)
              │                                │
              └────────── Pods (demo-api) ─────┘
```

GKE is the easiest of the three: the **target data plane (Envoy) is already a first-party option** via GKE Gateway — no separate install of Envoy Gateway is required.

Migration mechanics:

1. Same backend Service, two ingress paths.
2. **Cloud DNS weighted records** for cutover.
3. Pre-lower TTL to 60 s.
4. Decommission ingress-nginx after a clean 14-day soak on GKE Gateway.

## GKE-specific identity & secrets

| Concern | GKE mechanism |
|---|---|
| Pod → GCP API | **Workload Identity Federation for GKE** — federated short-lived tokens, no static SA keys |
| Secrets | **Secret Manager** + CSI Driver mount, or `Secret` objects with KMS encryption at rest |
| Container registry | **Artifact Registry** with pod-level IAM via Workload Identity |
| Image signing / provenance | **Binary Authorization** — admission control on signed images only |

## GKE-specific gotchas

| Gotcha | Detail |
|---|---|
| **Autopilot vs Standard** | Autopilot abstracts nodes and enforces secure defaults (non-root, resource requests required). Standard gives you node-level control. Pick deliberately. |
| **DataPlane V2** | eBPF dataplane via Cilium — better network policy + visibility, but cluster-level decision at create time (cannot toggle later on Standard). |
| **GKE Gateway is regional or global** | `global-external-managed` provisions a single global Anycast LB; `regional-external-managed` provisions per-region. Cost and latency differ. |
| **NEGs** | GCP load balancers route to pods via **Network Endpoint Groups** (NEG), not NodePorts. Faster, more accurate health, no kube-proxy hop. Make sure containers have the right NEG annotation. |
| **Cluster autoscaler / node-auto-provisioning** | NAP can create new node pools on demand for unschedulable pods — useful for AI/GPU bursts. |
| **GPU nodes** | NVIDIA `T4`, `A100`, `L4`, `H100` instance types. GKE auto-installs the GPU driver via DaemonSet. Taints/tolerations to keep cheap pods off GPU nodes. |
| **Cross-zone egress** | Within a region zone-to-zone egress is free for VM-to-VM but is metered in some configurations. Locality-aware load balancing still matters. |

## Observability on GKE

| Layer | GCP-native | OSS |
|---|---|---|
| Metrics | **Cloud Monitoring** / **Managed Service for Prometheus** | self-hosted Prometheus |
| Dashboards | **Cloud Monitoring dashboards** or **Managed Grafana** | self-hosted Grafana |
| Logs | **Cloud Logging** | Loki |
| Traces | **Cloud Trace** | Tempo / Jaeger |
| App Performance | **Cloud Profiler / Error Reporting** | OSS equivalents |

## GKE bare-minimum checklist (production)

- [ ] Regional cluster (control plane HA) in private VPC
- [ ] **Workload Identity Federation for GKE** enabled (no static SA keys)
- [ ] Decision on **Autopilot vs Standard** — Autopilot for "secure by default" greenfield
- [ ] **Artifact Registry** for images, **Binary Authorization** for signed-only admission
- [ ] **Cloud Armor** for WAF / DDoS in front of the external LB
- [ ] Ingress decision: **GKE Gateway** for greenfield Envoy-backed L7; Envoy Gateway / Istio when richer data plane needed
- [ ] **Managed Service for Prometheus + Grafana** wired up
- [ ] **Anthos Policy Controller / Gatekeeper** for guardrails (non-root, approved registry, resource limits)

## One-line summary

> "GKE is the friendliest of the three for the Envoy migration — GKE Gateway is already Envoy under the hood, so you don't deploy a second data plane, you just author `Gateway` and `HTTPRoute` against a Google-managed Envoy fleet. Workload Identity Federation replaces static SA keys, NEGs replace NodePort hops, and Cloud Armor sits in front for WAF. For richer L7 control or multi-cluster mTLS, drop in Envoy Gateway or Anthos Service Mesh."
