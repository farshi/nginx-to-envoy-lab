# Instrumentation — How demo-api Emits Prometheus Metrics

Reference doc for the metrics pipeline used by `services/demo-api`. The same pattern transfers to any Flask / Django / FastAPI service.

## The four pieces

```
┌────────────┐  HTTP  ┌──────────────┐  scrape  ┌────────────┐
│ Flask app  │───────▶│ /metrics     │◀─────────│ Prometheus │
│ (handlers) │        │ text format  │          │ (operator) │
└─────┬──────┘        └──────────────┘          └────────────┘
      │ before/after_request hooks                  ▲
      │ update Counter + Histogram                  │ ServiceMonitor
      ▼                                             │
prometheus_client registry  ────────────────────────┘
```

1. **Declare metrics** (module-level Counters + Histograms with bounded label sets).
2. **Update on every request** (`before_request` + `after_request` hooks).
3. **Expose `/metrics`** in Prometheus text format.
4. **Tell Prometheus to scrape it** via a `ServiceMonitor`.

## 1 · Declare metrics

```python
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST

REQUESTS = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["service", "tenant", "method", "path", "status"],
)
LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds",
    ["service", "tenant", "method", "path"],
)
```

Type cheat-sheet:

| Type | When to use | PromQL hint |
|------|------------|-------------|
| **Counter**  | values that only go up — request count, error count | `rate(metric[5m])` |
| **Gauge**    | values that go up *and* down — queue depth, connections, memory | read directly |
| **Histogram**| observations into buckets — latency, payload size | `histogram_quantile(0.99, sum(rate(metric_bucket[5m])) by (le))` |
| **Summary**  | client-computed quantiles, harder to aggregate | rarely needed; prefer Histogram |

Label rules (interview signal):

- Labels must be **bounded**. Never label by `user_id`, request URL with query params, request id, etc — cardinality explodes and Prometheus eats RAM.
- Good labels: `method`, `path` (template, not raw URL), `status_code`, `tenant`, `service`.
- Bad labels: `user_id`, `email`, full URLs, timestamps, anything unbounded.

## 2 · Update on every request

Flask hooks fire before and after the handler:

```python
@app.before_request
def mark_start():
    request._start_time = time.perf_counter()

@app.after_request
def collect_metrics(response):
    if request.path == "/metrics":
        return response                              # don't measure the scrape
    duration = time.perf_counter() - request._start_time
    labels = {
        "service": SERVICE_NAME,
        "tenant":  TENANT,
        "method":  request.method,
        "path":    request.path,
    }
    LATENCY.labels(**labels).observe(duration)
    REQUESTS.labels(status=response.status_code, **labels).inc()
    return response
```

Patterns to copy:

- Stamp `_start_time` in `before_request`; subtract in `after_request`.
- **Skip `/metrics` itself** or every scrape adds a sample about itself.
- `observe(duration)` on a Histogram → buckets + sum + count auto-update.
- `inc()` on a Counter → monotonically up.

## 3 · Expose `/metrics`

```python
from flask import Response

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)
```

`generate_latest()` serialises **all** registered metrics in the Prometheus text format:

```text
# HELP http_requests_total Total HTTP requests
# TYPE http_requests_total counter
http_requests_total{service="demo-api",tenant="shared",method="GET",path="/",status="200"} 1342

# HELP http_request_duration_seconds HTTP request latency in seconds
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{...,le="0.005"} 1200
http_request_duration_seconds_bucket{...,le="0.01"}  1330
http_request_duration_seconds_bucket{...,le="+Inf"}  1342
http_request_duration_seconds_sum{...}   3.91
http_request_duration_seconds_count{...} 1342
```

A Histogram emits three series per bucket combination: `_bucket{le=...}`, `_sum`, `_count`. PromQL uses these together to compute quantiles.

## 4 · Have Prometheus scrape it

The Service exposes port `http`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: demo-api
  labels: { app.kubernetes.io/name: demo-api }
spec:
  selector: { app.kubernetes.io/name: demo-api }
  ports:
    - { name: http, port: 80, targetPort: http }
```

The `ServiceMonitor` (a CRD shipped by Prometheus Operator) tells Prometheus *what to scrape*:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: demo-api
  namespace: monitoring
  labels: { release: kps }                # matches Prometheus's selector
spec:
  namespaceSelector: { matchNames: ["demo"] }
  selector:
    matchLabels: { app.kubernetes.io/name: demo-api }
  endpoints:
    - port: http
      path: /metrics
      interval: 15s
```

The Prometheus Operator watches `ServiceMonitor` / `PodMonitor` resources and reconfigures Prometheus to scrape them. Prometheus pulls on schedule — **pull model**, not push.

**Use `PodMonitor` instead** when the metrics port is not exposed by the Service (e.g. Envoy proxy's `:19001` admin port — see `manifests/envoy/servicemonitor.yaml`).

## End-to-end verification

```bash
# 1. App emits it
kubectl -n demo port-forward svc/demo-api 8088:80 &
curl -s localhost:8088/metrics | grep -E '^http_' | head

# 2. Prometheus picked up the scrape config
curl -s http://localhost:9091/api/v1/targets?state=active \
  | jq '.data.activeTargets[].labels.job' | sort -u

# 3. Querying the metric works
curl -s 'http://localhost:9091/api/v1/query?query=sum(rate(http_requests_total[1m]))' \
  | jq '.data.result'
```

## Gotchas that come up in interviews

### Multi-process workers (gunicorn / uwsgi)

`gunicorn --workers 2` runs two processes, each with its **own** in-memory metrics registry. A scrape hits one process at a time, so counts look partial and aggregate badly.

Two fixes:

- `--workers 1` (this lab's default — fine for a demo).
- For real prod, set `PROMETHEUS_MULTIPROC_DIR=/tmp/prom` and use the `multiprocess` collector so workers share a file-backed registry:

  ```python
  from prometheus_client import multiprocess, CollectorRegistry, generate_latest

  @app.get("/metrics")
  def metrics():
      registry = CollectorRegistry()
      multiprocess.MultiProcessCollector(registry)
      return Response(generate_latest(registry), mimetype=CONTENT_TYPE_LATEST)
  ```

### Cardinality

Every unique label-value combination is a separate time series. A label like `request_id` produces millions of series within hours and crashes Prometheus. **If a label can take more than ~100 values, do not put it on a metric.**

### Path templates, not raw URLs

`/users/42/orders/19` should report as `/users/{id}/orders/{id}` — otherwise every user ID becomes a new series. Flask's `request.url_rule` (when matched) gives the template; fall back to `request.path` for unmatched routes.

### Histogram bucket selection

The default Histogram buckets target web latency (`.005, .01, .025, ... 10`). For slower endpoints (model inference, background jobs) override with your own bucket boundaries; otherwise everything ends up in `+Inf` and percentiles become useless.

### Don't measure `/metrics` itself

Self-scrape loop adds samples on every Prometheus poll. Skip it in the `after_request` hook (this lab does).

## Equivalent patterns by framework

| Framework | Library |
|-----------|---------|
| **Flask** | `prometheus_client` (this lab) |
| **FastAPI** / Starlette | `prometheus-fastapi-instrumentator` |
| **Django** | `django-prometheus` |
| **Spring Boot** | Micrometer + Prometheus registry |
| **Node.js (Express)** | `prom-client` |
| **Go** | official `prometheus/client_golang` |

All produce the same `/metrics` text format. Only the wiring differs.

## Why this matters for the migration

Without app-level metrics you can only watch the ingress (nginx / Envoy) view of traffic. With app-level metrics you can attribute slowness to layers:

- `nginx p99` − `app p99` ≈ proxy + network overhead
- If `envoy p99` − `app p99` regresses but `app p99` is flat, **the proxy is the problem**, not the workload

That decomposition is the difference between *"things look slower"* and *"the new ingress added 8 ms of overhead, here's exactly which Envoy filter chain contributes."*
