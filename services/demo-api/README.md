# Demo API

Sample API service for the lab.

## Purpose

This is the workload used to demonstrate:

- safe deployment
- policy rejection
- runtime breakage
- rollback
- metrics, logs, and traces

Runtime demo knobs:

- `ERROR_RATE_PERCENT`: injects failures into normal request paths.
- `DEFAULT_SLOW_SECONDS`: controls `/slow` latency when no query value is passed.

## Phase 1

Keep it small and easy to reason about.

## Files

- `app.py` - HTTP API used by the lab
- `Dockerfile` - local image build for the demo
- `requirements.txt` - Python dependencies
- `manifests/base` - base Kubernetes manifests
