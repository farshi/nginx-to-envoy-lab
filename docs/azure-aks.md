# Azure AKS — Ingress & Service Mesh Reality

What AKS gives you out of the box, what is opt-in, and how the nginx → Envoy migration looks on Azure.

## What AKS gives you by default

AKS is more "batteries included" than EKS — Microsoft ships an opinionated set of add-ons that can be enabled at cluster creation.

| Default / common add-on | What it does |
|---|---|
| **Azure CNI** (or kubenet) | Pod networking — Azure CNI gives pods real VNet IPs; kubenet uses overlay |
| **kube-proxy** | Service routing |
| **CoreDNS** | cluster DNS |
| **Azure Disk / Azure Files CSI** | persistent volumes |
| **Microsoft Defender for Containers** (opt-in) | runtime security + image scanning |
| **Azure Monitor for Containers** (opt-in) | metrics + logs into Log Analytics |
| **Application Gateway Ingress Controller (AGIC)** (opt-in) | provisions/configures **Azure Application Gateway** as the L7 ingress |
| **Application Gateway for Containers (AGC)** (newer, opt-in) | Microsoft's newer Gateway-API-native ingress, replaces AGIC for greenfield |
| **Istio-based managed mesh** (opt-in) | service mesh as an AKS add-on, no DIY install |

## Ingress options on AKS

### Option 1 — Application Gateway for Containers (AGC) — the modern Microsoft choice

AGC is Microsoft's **Gateway-API-native** managed L7 ingress. Provisioned as an Azure resource, configured via `Gateway` / `HTTPRoute` objects in the cluster.

- Fully managed data plane (Microsoft runs the LB hardware).
- Supports header-based routing, weighted traffic split, mTLS to backend, request mirroring.
- Replaces AGIC for new deployments; AGIC remains supported.

### Option 2 — Application Gateway Ingress Controller (AGIC)

Older. Translates K8s `Ingress` objects into Azure Application Gateway routing rules. Still common in brownfield estates.

### Option 3 — Envoy Gateway in-cluster behind an Azure Load Balancer

Same pattern as the EKS Envoy story. Envoy Gateway runs in the cluster; its `LoadBalancer` Service maps to an **Azure Standard Load Balancer** (L4) or an **Azure Application Gateway** if you want the platform LB to be L7 too.

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.2.0 -n envoy-gateway-system --create-namespace
```

### Option 4 — Istio managed add-on

AKS lets you enable an Istio-based service mesh as an add-on. Microsoft runs the control plane upgrade cadence. Useful when **east-west mTLS** and per-service policy are the real ask.

## Migration shape on AKS

```
                Azure DNS (weighted routing via Azure Traffic Manager)
                              │
              ┌───────────────┴────────────────┐
              ▼                                ▼
   Application Gateway (old)          Application Gateway for Containers
   AGIC + ingress-nginx               or Envoy Gateway behind ALB
              │                                │
              └───────── Pods (demo-api) ──────┘
```

Migration mechanics:

1. Same backend Service, two ingress paths (AGIC/nginx vs AGC/Envoy).
2. **Azure Traffic Manager** for weighted DNS routing during cutover (alternative to Azure DNS weighted records, which Azure does not natively support — Traffic Manager is the canonical tool).
3. Pre-lower TTL on the Traffic Manager profile to 60 s.
4. Decommission AGIC + nginx only after a clean 14-day soak on AGC / Envoy.

## AKS-specific identity & secrets

| Concern | AKS mechanism |
|---|---|
| Pod → Azure resource | **Azure AD Workload Identity** (the AKS equivalent of IRSA) — federated identity via OIDC, short-lived tokens, no static credentials |
| Secrets | **Azure Key Vault** with the **Secrets Store CSI Driver** mounting secrets at runtime |
| Container registry | **ACR (Azure Container Registry)** with AKS-managed pull credentials via AAD |
| Image signing / supply chain | ACR Tasks + Notation / Cosign + Defender for Containers scanning |

## AKS-specific gotchas

| Gotcha | Detail |
|---|---|
| **Azure CNI vs kubenet** | Azure CNI gives pods VNet IPs but burns through subnet space fast — size your subnets accordingly. Kubenet overlay uses NAT and is lighter on IPs but slower for some east-west patterns. |
| **AGIC limitations** | AGIC ties you to `Ingress` API and Azure Application Gateway feature set. Canary / mirror / advanced routing is friendlier in AGC or Envoy. |
| **Service Principal vs Managed Identity** | Always prefer **Managed Identity** (system- or user-assigned) over Service Principals with rotating secrets. **Workload Identity** is the modern choice for pods. |
| **Cluster autoscaler** | Native cluster autoscaler exists; **Karpenter for AKS** is now in preview / GA — same flexible node-provisioning model as EKS. |
| **GPU nodes** | `Standard_NC*`, `Standard_ND*` series. NVIDIA device plugin via the AKS GPU image or manual install. |
| **Outbound networking** | Default outbound is via the cluster Standard Load Balancer's outbound rules; for predictable egress, use a **NAT Gateway** or **Azure Firewall**. |

## Observability on AKS

| Layer | Azure-native | OSS |
|---|---|---|
| Metrics | **Azure Managed Prometheus** | self-hosted Prometheus |
| Dashboards | **Azure Managed Grafana** | self-hosted Grafana |
| Logs | **Azure Monitor / Log Analytics** | Loki / OpenSearch |
| Traces | **Azure Monitor Application Insights** | Tempo / Jaeger |
| Container insights | **Azure Monitor for Containers** | kube-state-metrics + node-exporter |

## AKS bare-minimum checklist (production)

- [ ] Multi-zone node pools (system + user pools separated)
- [ ] **Azure CNI** with sufficient subnet sizing, or kubenet for lower density
- [ ] **Workload Identity** enabled (federated identity, no static creds)
- [ ] **Key Vault + Secrets Store CSI Driver** for secrets
- [ ] **ACR** wired up for image pulls via AAD
- [ ] Ingress decision made: **AGC** for greenfield, AGIC during brownfield, Envoy Gateway when richer L7 needed
- [ ] **Microsoft Defender for Containers** enabled for runtime + image scanning
- [ ] Observability via Azure Managed Prometheus + Grafana (or OSS equivalent)
- [ ] **Azure Policy for AKS** for guardrails (allowed registries, non-root, resource limits)

## One-line summary

> "AKS is more opinionated than EKS — Microsoft ships Application Gateway controllers as native options (AGIC legacy, AGC modern + Gateway-API-native) and an Istio managed mesh add-on. For ingress-nginx → Envoy, the cleanest cutover is to AGC or Envoy Gateway, with Workload Identity replacing service principals and Traffic Manager handling weighted DNS routing during the ramp."
