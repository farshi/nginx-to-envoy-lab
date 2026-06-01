# nginx-to-envoy-lab

A reproducible local lab that runs **ingress-nginx and Envoy Gateway side by side** in front of the same backend, scrapes both with Prometheus, renders RED metrics on a Grafana dashboard, and shows the SLO gates that decide whether a real cutover is safe.

It exists to make one claim defensible:

> "The migration is successful when, under load, Envoy's error rate, latency, and upstream health match nginx's — measured, not assumed."

## What's in the box

- **k3d** single-node cluster (built-in Traefik disabled)
- **ingress-nginx** with `/metrics` enabled (the "before" stack)
- **Envoy Gateway** + GatewayClass / Gateway / HTTPRoute (the "after" stack)
- A shared **demo-api** (Python Flask) exposing `/metrics` and OpenTelemetry traces
- **kube-prometheus-stack** (Prometheus + Grafana + ServiceMonitors)
- ServiceMonitors scraping both ingress paths
- A **continuous load generator** hitting both hostnames in parallel
- A **side-by-side Grafana dashboard** (rate / errors / p99 latency for each stack)
- A **MIGRATION_SUCCESS.md** with explicit SLO gates

## Architecture

```
                     ┌─ ingress-nginx ──┐
        load gen ────┤                  ├──▶  demo-api  ──▶  Pods
                     └─ envoy gateway ──┘
                              │
                              ▼  scrape /metrics
                       Prometheus
                              │
                              ▼
                         Grafana  (RED side-by-side, SLO gates)
```

Two hostnames resolve to the same backend through different controllers:

| Hostname | Path | Controller |
|---|---|---|
| `nginx-demo.localhost` | `/` | ingress-nginx |
| `envoy-demo.localhost` | `/` | Envoy Gateway |

## Quick start

```bash
make up           # k3d cluster + all installs + manifests + envoy tunnel
make traffic      # background load against both hostnames
make grafana      # open Grafana at http://localhost:3001  (admin / admin)
make prom         # open Prometheus at http://localhost:9091
make demo         # curl-test both paths
make tunnel       # restart the envoy :8082 port-forward (k3d serverlb only forwards one LB)
make down         # destroy cluster
```

### Why two ports work differently

k3d's `serverlb` (klipper-lb) forwards a host port to **one** in-cluster `LoadBalancer` Service per backend port. Ingress-nginx claimed it first, so `http://nginx-demo.localhost:8081/` flows through `serverlb` directly. The Envoy proxy LB never gets a `serverlb` slot, so `make tunnel` keeps a `kubectl port-forward svc/envoy-edge 8082:80` running. `make up` starts it automatically.

Add the demo hostnames once:

```bash
echo "127.0.0.1 nginx-demo.localhost envoy-demo.localhost portal.localhost" | sudo tee -a /etc/hosts
```

The **portal** (single-page mission control with embedded Grafana / Prom / migration steps) is served from inside the cluster after `make up`:

```
http://portal.localhost:8081/
```

To rebuild the portal after editing `portal.html` locally:

```bash
make portal      # re-create ConfigMap from portal.html and restart the pod
```

## What to look at in Grafana

Open the **`Ingress Migration — nginx vs Envoy`** dashboard. Three rows, two panels each:

1. **Request rate** — both stacks should track load generator output.
2. **Error rate (5xx)** — Envoy must not exceed nginx baseline + 0.1 %.
3. **p99 latency** — Envoy p99 must not exceed nginx p99 × 1.10.

If any panel diverges, the migration is **not safe** to ramp. See `docs/MIGRATION_SUCCESS.md`.

## Why this is interesting

- Real RED metrics from a real backend, two ingress paths, one dashboard.
- Demonstrates the **shift from frozen Ingress API to Gateway API** (HTTPRoute with native traffic-split).
- Shows the **xDS / config-delivery** signals (`control_plane_connected_state`, `cds_update_failure`) that explain Envoy's zero-reload story.
- The cutover policy in `docs/MIGRATION_SUCCESS.md` is the same one you'd run in production.

## Layout

```
manifests/
  demo/        namespace + demo-api Deployment/Service + ServiceMonitor
  nginx/       Ingress object routing nginx-demo.localhost
  envoy/       GatewayClass + Gateway + HTTPRoute + Envoy ServiceMonitor
  loadgen/     hey-based traffic generator
observability/ kube-prometheus-stack values
dashboards/    Grafana dashboard ConfigMap (picked up by Grafana sidecar)
services/      demo-api Python Flask source (with /metrics + OTel)
docs/          ARCHITECTURE.md, MIGRATION_SUCCESS.md
scripts/       bootstrap.sh and helpers
```

## Documentation

| Doc | Purpose |
|---|---|
| [`docs/WHY_MIGRATE.md`](docs/WHY_MIGRATE.md) | The case for the migration — frozen Ingress API, 2025 CVE pressure, feature gap, comparison table |
| [`docs/ROLLOUT.md`](docs/ROLLOUT.md) | Phase-by-phase rollout playbook with shadow, weighted ramp, and four-level rollback |
| [`docs/MIGRATION_SUCCESS.md`](docs/MIGRATION_SUCCESS.md) | The SLO gates that decide whether a step advances or rolls back |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Control plane vs data plane, why Gateway API over frozen Ingress |
| [`docs/INSTRUMENTATION.md`](docs/INSTRUMENTATION.md) | How the Flask demo-api emits Prometheus metrics — Counter/Histogram, /metrics endpoint, ServiceMonitor wiring, gotchas (cardinality, multi-process workers, histogram buckets) |
| [`docs/aws-eks.md`](docs/aws-eks.md) | EKS specifics — bare-cluster defaults, AWS Load Balancer Controller, IRSA, Karpenter |
| [`docs/azure-aks.md`](docs/azure-aks.md) | AKS specifics — AGIC vs AGC, Workload Identity, managed Istio add-on |
| [`docs/gcp-gke.md`](docs/gcp-gke.md) | GKE specifics — GKE Gateway (Envoy under the hood), NEGs, Workload Identity Federation |

## Status

Single-node local lab. Reflects the production migration pattern but runs on a laptop. Not multi-cluster, not multi-tenant — focus is the ingress comparison. See `docs/aws-eks.md`, `docs/azure-aks.md`, `docs/gcp-gke.md` for how the same pattern lands on each managed Kubernetes.
