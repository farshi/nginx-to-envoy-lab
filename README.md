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
make up           # k3d cluster + all installs + manifests + dashboards
make traffic      # background load against both hostnames
make grafana      # open Grafana at http://localhost:3000  (admin / admin)
make prom         # open Prometheus at http://localhost:9090
make demo         # ascii summary + curl-test both paths
make down         # destroy cluster
```

Add the demo hostnames once:

```bash
echo "127.0.0.1 nginx-demo.localhost envoy-demo.localhost" | sudo tee -a /etc/hosts
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

## Status

Single-node local lab. Reflects the EKS production pattern but runs on a laptop. Not multi-cluster, not multi-tenant — focus is the ingress comparison.
