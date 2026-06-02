---
title: "nginx -> Envoy Gateway Migration Lab"
author: "Reza Farshi"
date: "June 2026"
geometry: "top=2cm, bottom=2cm, left=2.2cm, right=2.2cm"
fontsize: 10.5pt
mainfont: "Helvetica Neue"
monofont: "Menlo"
monofontoptions: "Scale=0.78"
colorlinks: true
urlcolor: "NavyBlue"
header-includes:
  - \usepackage{booktabs}
  - \usepackage{xcolor}
  - \usepackage{fancyhdr}
  - \usepackage{tabularx}
  - \usepackage{array}
  - \definecolor{accent}{RGB}{30, 100, 200}
  - \definecolor{muted}{RGB}{100, 100, 100}
  - \definecolor{rulegray}{RGB}{180, 180, 180}
  - \pagestyle{fancy}
  - \fancyhf{}
  - \lhead{\textcolor{muted}{\small \textbf{nginx -> Envoy Gateway Migration Lab} \quad|\quad Reza Farshi}}
  - \rhead{\textcolor{muted}{\small github.com/farshi/nginx-to-envoy-lab}}
  - \cfoot{\textcolor{muted}{\small \thepage}}
  - \renewcommand{\headrulewidth}{0.3pt}
  - \renewcommand{\headrule}{\color{rulegray}\hrule width\headwidth height\headrulewidth}
  - \setlength{\parskip}{4pt}
---

\begin{center}
\large\textbf{Problem:} migrating 100 nginx Ingresses to Envoy Gateway — each with different annotations,\\
with no human watching dashboards, and with sub-10-second rollback on breach.
\end{center}

\vspace{0.3cm}
\noindent\textcolor{rulegray}{\rule{\linewidth}{0.4pt}}
\vspace{0.1cm}

## What Was Built

A production-grade Kubernetes lab that solves two concrete problems at the 100-endpoint scale:

- **Automated rollback** — a `CronJob` queries Prometheus every 60 s; on breach it rolls back every canary `HTTPRoute` fleet-wide with no human in the loop
- **Annotation translation** — `ingress2gateway` (official Kubernetes SIG tool) + per-Ingress policy stub generation converts the full annotation set to Gateway API CRDs automatically

**Stack:** k3d · Envoy Gateway v1.2 · ingress-nginx · kube-prometheus-stack · ArgoCD · Gateway API

---

## Architecture

```
  :8081 ──> ingress-nginx ──┐
                             +--> demo-api       Prometheus <-- ServiceMonitors
  :8082 ──> Envoy Gateway ──┘                   ArgoCD     <-- manifests/
             GatewayClass / Gateway / HTTPRoute
```

Both stacks serve the same backend simultaneously. Canary = `backendRefs` weight split inside one HTTPRoute. No DNS changes during ramp.

---

## Automated Rollback

\textcolor{muted}{\small\textit{Core insight: at 100 endpoints you cannot watch per-route dashboards. Rollback must be metric-driven and fleet-scoped.}}

**`canary-watchdog` CronJob** — fires every 60 s, two breach conditions:

```
envoy 5xx / total  >  5%        -> rollback
p99 downstream latency > 2000ms -> rollback
```

All HTTPRoutes labeled `migration=canary` are targeted in a single loop — 100 routes, ~5 to 10 seconds:

```bash
kubectl get httproute -A -l migration=canary ... | while read ns name; do
  kubectl delete httproute "$name" -n "$ns"
done
```

**Three rollback levels:**

| Level | Action | Latency |
|---|---|---|
| L1 | Patch weights: nginx=100, envoy=0 | < 2 s |
| L2 | Delete HTTPRoute (xDS pushes removal) | < 5 s |
| L3 | Delete Gateway (nginx handles 100%) | < 5 s |

**Operational commands:**

```bash
make rollback-install    # deploy CronJob + RBAC + PrometheusRule
make rollback-test       # manual trigger  (DRY_RUN=true to preview)
make canary-status       # weight split across all canary HTTPRoutes
make chaos               # inject 10% 500s -> watch watchdog fire automatically
```

---

## Annotation Translation

\textcolor{muted}{\small\textit{Each of 100 Ingresses carries different annotations. Manual per-route translation does not scale.}}

**`make translate-annotations`** runs two steps:

1. **`ingress2gateway`** (official SIG tool — `sigs.k8s.io/ingress2gateway`) reads live Ingresses and emits `HTTPRoute` manifests for common annotations
2. **`scripts/translate-annotations.sh`** covers the remainder — emits `BackendTrafficPolicy` + `SecurityPolicy` stubs per Ingress, flags hard cases

| nginx annotation | Envoy Gateway CRD | Field |
|---|---|---|
| `proxy-read-timeout` | `BackendTrafficPolicy` | `timeout.http.requestTimeout` |
| `proxy-next-upstream-tries` | `BackendTrafficPolicy` | `retry.numRetries` |
| `limit-rps` | `BackendTrafficPolicy` | `rateLimit.local` |
| `whitelist-source-range` | `SecurityPolicy` | `ipAllowList.cidrRanges` |
| `auth-url` | `SecurityPolicy` | `extAuth.http` |
| `rewrite-target` | HTTPRoute filter | `URLRewrite.path` |
| `server-snippet` / `modsecurity` | `EnvoyExtensionPolicy` | Wasm — **manual work required** |

Each policy attaches via `targetRef` scoped to its own HTTPRoute — 100 routes stay independent.

```bash
make install-ingress2gateway   # install official SIG tool
make annotation-audit          # fleet-wide inventory of every annotation
make translate-annotations     # generate HTTPRoutes + policy stubs -> manifests/generated/
```

---

## Failure Injection + Demo

```bash
make up            # bootstrap full cluster (~4 min on MacBook)
make chaos         # 10% random 500s -> watchdog auto-rollback fires
make bad-traffic   # hammer /fail -> visible error spike
make slow-traffic  # hammer /slow?seconds=2 -> p99 breach
make demo-step1    # through demo-step6: full live walkthrough
```

\vspace{0.3cm}
\noindent\textcolor{rulegray}{\rule{\linewidth}{0.4pt}}

\begin{center}
\textbf{github.com/farshi/nginx-to-envoy-lab} \quad\textcolor{muted}{|}\quad \texttt{make up} to run locally \quad\textcolor{muted}{|}\quad \texttt{reza.farshi@gmail.com}
\end{center}
