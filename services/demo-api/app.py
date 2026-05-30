import os
import random
import time
import base64
import json
from flask import Flask, jsonify, request, Response
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST

from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor


SERVICE_NAME = os.getenv("SERVICE_NAME", "demo-api")
SERVICE_VERSION = os.getenv("SERVICE_VERSION", "0.1.0")
TENANT = os.getenv("TENANT", "shared")
OTEL_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "").strip()
ERROR_RATE_PERCENT = max(0.0, min(float(os.getenv("ERROR_RATE_PERCENT", "0")), 100.0))
DEFAULT_SLOW_SECONDS = max(0.0, min(float(os.getenv("DEFAULT_SLOW_SECONDS", "0.25")), 5.0))
identity_ISSUER = os.getenv("identity_ISSUER", "https://identity.example.com/oauth2/default")
identity_AUDIENCE = os.getenv("identity_AUDIENCE", "orders-api")


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


def decode_demo_jwt_payload(token: str) -> dict:
    parts = token.split(".")
    if len(parts) != 3:
        raise ValueError("token must have JWT header.payload.signature shape")
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    return json.loads(base64.urlsafe_b64decode(payload.encode("utf-8")))


def require_customer_token() -> tuple[dict | None, tuple | None]:
    header = request.headers.get("Authorization", "")
    if not header.startswith("Bearer "):
        return None, (jsonify({"status": "denied", "reason": "missing bearer token"}), 401)
    try:
        claims = decode_demo_jwt_payload(header.removeprefix("Bearer ").strip())
    except (ValueError, json.JSONDecodeError, UnicodeDecodeError) as error:
        return None, (jsonify({"status": "denied", "reason": str(error)}), 401)

    now = int(time.time())
    expected = {
        "iss": identity_ISSUER,
        "aud": identity_AUDIENCE,
    }
    for key, value in expected.items():
        if claims.get(key) != value:
            return None, (
                jsonify(
                    {
                        "status": "denied",
                        "reason": f"invalid {key}",
                        "expected": value,
                    }
                ),
                403,
            )
    if int(claims.get("exp", 0)) <= now:
        return None, (jsonify({"status": "denied", "reason": "token expired"}), 401)
    if not claims.get("customer_id") or not claims.get("client_id"):
        return None, (
            jsonify({"status": "denied", "reason": "missing customer_id or client_id claim"}),
            403,
        )
    return claims, None


def configure_tracing() -> None:
    resource = Resource.create(
        {
            "service.name": SERVICE_NAME,
            "service.version": SERVICE_VERSION,
            "service.namespace": "platform-guardrails-lab",
            "tenant": TENANT,
        }
    )
    provider = TracerProvider(resource=resource)
    if OTEL_ENDPOINT:
        provider.add_span_processor(
            BatchSpanProcessor(OTLPSpanExporter(endpoint=OTEL_ENDPOINT))
        )
    else:
        provider.add_span_processor(BatchSpanProcessor(ConsoleSpanExporter()))
    trace.set_tracer_provider(provider)


configure_tracing()
app = Flask(__name__)
FlaskInstrumentor().instrument_app(app)


@app.after_request
def collect_metrics(response):
    path = request.path
    if path == "/metrics":
        return response
    duration = time.perf_counter() - getattr(request, "_start_time", time.perf_counter())
    labels = {
        "service": SERVICE_NAME,
        "tenant": TENANT,
        "method": request.method,
        "path": path,
    }
    LATENCY.labels(**labels).observe(duration)
    REQUESTS.labels(status=response.status_code, **labels).inc()
    return response


@app.before_request
def mark_start():
    request._start_time = time.perf_counter()
    if request.path in {"/healthz", "/readyz", "/metrics", "/fail"}:
        return None
    if ERROR_RATE_PERCENT > 0 and random.uniform(0, 100) < ERROR_RATE_PERCENT:
        return jsonify({"status": "error", "message": "injected demo failure"}), 500
    return None


@app.get("/")
def index():
    return jsonify(
        {
            "service": SERVICE_NAME,
            "version": SERVICE_VERSION,
            "tenant": TENANT,
            "runtime": "python-flask",
            "message": (
                "Hello, I am a Flask endpoint. I emit Prometheus metrics, "
                "structured logs, and OpenTelemetry traces for the platform guardrails demo."
            ),
        }
    )


@app.get("/healthz")
def healthz():
    return jsonify({"status": "ok"}), 200


@app.get("/readyz")
def readyz():
    return jsonify({"status": "ready"}), 200


@app.get("/slow")
def slow():
    delay = float(request.args.get("seconds", str(DEFAULT_SLOW_SECONDS)))
    delay = max(0.0, min(delay, 5.0))
    time.sleep(delay)
    return jsonify({"status": "ok", "slept_seconds": delay})


@app.get("/fail")
def fail():
    return jsonify({"status": "error", "message": "intentional demo failure"}), 500


@app.get("/customer/orders")
def customer_orders():
    claims, error = require_customer_token()
    if error:
        return error
    return jsonify(
        {
            "status": "ok",
            "service": SERVICE_NAME,
            "tenant": TENANT,
            "auth_model": "local identity demo token; platform policy is the real gateway boundary",
            "customer": {
                "id": claims["customer_id"],
                "client_id": claims["client_id"],
                "scope": claims.get("scope", "orders:read"),
            },
            "orders": [
                {"id": "ord-1001", "state": "processing"},
                {"id": "ord-1002", "state": "shipped"},
            ],
        }
    )


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    port = int(os.getenv("PORT", "8080"))
    app.run(host="0.0.0.0", port=port)
