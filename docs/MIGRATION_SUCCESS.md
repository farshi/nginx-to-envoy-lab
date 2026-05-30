# Migration Success Criteria

The migration is **safe to ramp** only while every gate below is green. A breach on any gate fails the ramp step and triggers automatic rollback to the prior weight.

## SLO gates (compared to the nginx baseline)

| Signal              | Gate                                                       | Source                              |
|---------------------|------------------------------------------------------------|-------------------------------------|
| Error rate (5xx)    | Envoy 5xx % ≤ nginx baseline + **0.1 %**                   | `nginx_ingress_controller_requests`, `envoy_cluster_upstream_rq_xx` |
| Latency p99         | Envoy p99 ≤ nginx p99 × **1.10**                           | `*_request_duration_seconds_bucket`, `envoy_cluster_upstream_rq_time_bucket` |
| Healthy endpoints   | Envoy healthy endpoints **==** nginx healthy endpoints     | `envoy_cluster_membership_healthy`  |
| Circuit breaker     | `upstream_cx_overflow` rate **== 0**                       | `envoy_cluster_upstream_cx_overflow` |
| xDS sync            | `control_plane_connected_state == 1` on every Envoy        | `envoy_control_plane_connected_state` |
| Memory              | Envoy RSS ≤ nginx RSS × **2**                              | `container_memory_working_set_bytes` |
| Outlier ejection    | `outlier_detection_ejections_active == 0` (steady state)   | `envoy_cluster_outlier_detection_ejections_active` |

## Ramp policy

1. **Parallel stack** — Envoy deployed alongside nginx (this lab's state).
2. **Shadow / mirror** — 100 % of prod traffic mirrored to Envoy; diff response codes and latency for 24 h. Zero user blast-radius.
3. **Weighted ramp** — DNS-weighted cutover:

   ```
   5 %  → 30 min hold → check gates
   25 % → 30 min hold → check gates
   50 % → 60 min hold → check gates
   100 % → soak 24 h
   ```

4. **Rollback** — any gate breach restores the previous DNS weight within 60 s. DNS TTL pre-lowered to 60 s before step 1.
5. **Decommission** — nginx kept warm 14 days after 100 %; remove only after a clean soak.

## What "successful" means in one sentence

> Under load, Envoy's RED metrics match the nginx baseline within the gate tolerances, upstream and xDS signals are clean, and the ramp completes the soak window without a rollback.

That is the claim a Grafana screenshot from this lab supports — not a slide.
