# AWS EKS — Ingress & Service Mesh Reality

What ships with EKS, what does not, and how the nginx → Envoy migration looks on AWS specifically.

## What EKS gives you by default

EKS ships an **almost bare** cluster. There is no opinionated ingress, no service mesh, no observability stack. The cluster comes with:

| Default add-on | What it does | Status |
|---|---|---|
| **VPC CNI (`amazon-vpc-cni-k8s`)** | Pods get real VPC IPs from the ENI of the host node | always on |
| **kube-proxy** | iptables / IPVS for Service routing | always on |
| **CoreDNS** | cluster DNS resolver | always on |
| **EBS CSI driver** | EBS-backed PersistentVolumes (optional add-on, almost always installed) | opt-in but standard |

That is it. No ingress controller, no Gateway API CRDs, no Prometheus, no service mesh.

> **In short:** Unlike k3d or GKE, EKS ships nothing for ingress — just VPC CNI, kube-proxy, CoreDNS. You install the AWS Load Balancer Controller for ALB/NLB, or Envoy Gateway / Istio if you need richer L7.

## The ingress layer you install

### Option 1 — AWS Load Balancer Controller (the AWS-native default)

The controller is a Helm-installed pod in your cluster. It watches Ingress / Gateway / Service objects and calls AWS APIs to provision **real ALBs (L7)** or **NLBs (L4)**.

```bash
# IAM via IRSA (no static keys)
eksctl create iamserviceaccount \
  --cluster my-cluster --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::ACCT:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve

helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=my-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```

| Concern | Who manages it |
|---|---|
| The **controller pod** | You (Helm) |
| The **ALB / NLB** AWS resource | AWS (provisioned by the controller via API) |
| IAM permissions | **IRSA** (IAM Roles for Service Accounts) — short-lived STS creds via OIDC, never static keys |

### Option 2 — Envoy Gateway behind an NLB

For richer L7 — canary, header routing, traffic mirroring, mTLS — install Envoy Gateway in-cluster. The Envoy proxy Service is `LoadBalancer` type, which the AWS LB Controller turns into an **NLB** by default.

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.2.0 -n envoy-gateway-system --create-namespace
```

Annotate the Envoy proxy Service for NLB:

```yaml
service.beta.kubernetes.io/aws-load-balancer-type: external
service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
```

### Option 3 — Istio / Gloo / Linkerd

Used when **east-west mTLS + per-service policy** are the goal. Heavier. Pick deliberately.

## Migration shape on EKS

```
        Route 53 (weighted, low TTL)
                 │
       ┌─────────┴─────────┐
       ▼                   ▼
   ALB (old)            NLB (new)
   ingress-nginx        Envoy Gateway
   target group         target group
       │                   │
       └────── Pods (demo-api) ──────┘
```

Migration mechanics:

1. **Same backend Service**, two ingress paths.
2. **Two load balancers** — old ALB in front of nginx, new NLB in front of Envoy.
3. **Route 53 weighted records** for cutover (5 → 25 → 50 → 100 %).
4. **Pre-lower TTL to 60 s** before step 1 (the silent killer of fast rollbacks).
5. Decommission the ALB only after 14 days of 100 % on Envoy.

## EKS-specific gotchas

| Gotcha | Detail |
|---|---|
| **DNS TTL** | Route 53 alias TTLs aren't user-settable, but A-record TTLs are. Set the **A record** TTL to 60 s pre-cutover. |
| **Target groups** | NLB target type = `ip` (pod IPs via VPC CNI) is the modern choice. `instance` targets route via NodePort + kube-proxy = extra hop. |
| **Health checks** | Configure ALB/NLB health checks against the Envoy admin `/ready` or proxy listener — not against backend pods. |
| **IRSA** | Always prefer IRSA over IAM user keys. Pods get **short-lived STS credentials** via the cluster OIDC provider; auto-rotated; small blast radius. |
| **Cross-AZ egress cost** | Same-AZ pod-to-pod traffic is free; cross-AZ has a per-GB cost. Envoy **locality-aware load balancing** prefers same-AZ endpoints — turn it on, cite the bill. |
| **VPC CNI ENI limits** | Pod density per node is bounded by ENI/IP limits of the instance type. Karpenter helps by picking instance types with sufficient ENIs. |
| **Karpenter for bursty workloads** | Replaces Cluster Autoscaler for fast, instance-type-flexible node provisioning. Critical for AI/GPU bursts where node start time matters. |
| **GPU nodes** | `g4dn` / `g5` / `p4` / `p5` families. **NVIDIA device plugin** required. Use taints/tolerations so only GPU pods land on expensive nodes. Spot for training, on-demand for inference. |

## Observability on EKS

| Layer | AWS-managed option | Open-source option |
|---|---|---|
| Metrics | **AMP** (Amazon Managed Prometheus) | self-hosted Prometheus |
| Dashboards | **AMG** (Amazon Managed Grafana) | self-hosted Grafana |
| Logs | **CloudWatch Logs**, **OpenSearch** | Loki |
| Traces | **AWS X-Ray** | Tempo / Jaeger |
| Container metrics | **CloudWatch Container Insights** | kube-state-metrics + node-exporter |

For a regulated workload the AMP / AMG combo removes the operational burden of self-hosting Prometheus and Grafana; the PromQL surface is unchanged.

## EKS bare-minimum checklist (production)

- [ ] EKS control plane in a multi-AZ private VPC
- [ ] Worker nodes via **managed node groups** or **Karpenter**
- [ ] **IRSA** for every workload that calls AWS APIs (never static keys)
- [ ] **AWS Load Balancer Controller** installed (for ALB / NLB)
- [ ] Default add-ons up to date (VPC CNI, kube-proxy, CoreDNS, EBS CSI)
- [ ] An ingress / Gateway layer chosen and installed (ingress-nginx today → Envoy Gateway after migration)
- [ ] Observability stack wired (AMP+AMG or self-hosted kube-prometheus-stack)
- [ ] Security boundaries: **SCPs** at the org level, **IAM** least-privilege per workload, **KMS** for secrets, **VPC SGs + NACLs** for network segmentation, **GuardDuty** for runtime threat detection, **Inspector** for image scanning

## One-line summary

> "On EKS the cluster ships almost bare — VPC CNI, kube-proxy, CoreDNS. Ingress is something you install. AWS Load Balancer Controller for ALB/NLB; Envoy Gateway when you need richer L7. Pods get AWS perms via IRSA, never static keys. Cross-AZ egress cost makes locality-aware load balancing a real lever, not a footnote."
