SHELL := /bin/sh
SHOW = @printf '\033[32m$$ %s\033[0m\n'

CLUSTER ?= migrate
IMAGE_REPO ?= demo-api
IMAGE_TAG ?= 0.1.0
NAMESPACE ?= demo

.PHONY: help up cluster image install-nginx install-envoy install-monitoring \
        apply traffic grafana prom demo down clean

help:
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

up: cluster image install-monitoring install-nginx install-envoy install-argocd apply argocd-app tunnel ## End-to-end bootstrap (cluster + all controllers + ArgoCD + manifests + envoy tunnel)

cluster: ## Create k3d cluster (Traefik disabled, ports exposed for both ingresses + Grafana + Prom)
	$(SHOW) "k3d cluster create $(CLUSTER)"
	@k3d cluster create $(CLUSTER) \
		--k3s-arg "--disable=traefik@server:0" \
		--port "8081:80@loadbalancer" \
		--port "8082:8080@loadbalancer" \
		--port "3001:30300@server:0" \
		--port "9091:30090@server:0" \
		--agents 1 --wait
	@kubectl create ns $(NAMESPACE) || true

image: ## Build demo-api and import to k3d
	$(SHOW) "docker build demo-api"
	@docker build -t $(IMAGE_REPO):$(IMAGE_TAG) services/demo-api
	@k3d image import $(IMAGE_REPO):$(IMAGE_TAG) -c $(CLUSTER)

install-nginx: ## Install ingress-nginx with metrics enabled
	$(SHOW) "helm install ingress-nginx"
	@helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
	@helm repo update >/dev/null
	@helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
		-n ingress-nginx --create-namespace \
		--set controller.metrics.enabled=true \
		--set controller.metrics.serviceMonitor.enabled=true \
		--set controller.metrics.serviceMonitor.additionalLabels.release=kps \
		--set controller.service.type=LoadBalancer \
		--wait

install-envoy: ## Install Envoy Gateway
	$(SHOW) "helm install envoy-gateway"
	@helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
		--version v1.2.0 -n envoy-gateway-system --create-namespace --wait
	@kubectl wait -n envoy-gateway-system deploy/envoy-gateway \
		--for=condition=Available --timeout=300s

install-monitoring: ## Install kube-prometheus-stack (Prometheus + Grafana)
	$(SHOW) "helm install kube-prometheus-stack"
	@helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
	@helm repo update >/dev/null
	@helm upgrade --install kps prometheus-community/kube-prometheus-stack \
		-n monitoring --create-namespace \
		-f observability/kube-prometheus-stack-values.yaml \
		--wait

apply: portal-configmap ## Apply all lab manifests (demo + nginx + envoy + loadgen + dashboard + portal)
	$(SHOW) "kubectl apply manifests"
	@kubectl apply -f manifests/demo/
	@kubectl apply -f manifests/nginx/
	@kubectl apply -f manifests/envoy/
	@kubectl apply -f manifests/loadgen/
	@kubectl apply -f manifests/portal/
	@kubectl apply -f dashboards/

portal-configmap: ## (Re)create the portal-html ConfigMap from local portal.html
	@kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f - >/dev/null
	@kubectl -n $(NAMESPACE) create configmap portal-html \
		--from-file=portal.html=portal.html \
		--dry-run=client -o yaml | kubectl apply -f -

portal: portal-configmap ## Update portal-html ConfigMap and bounce the portal pod
	@kubectl apply -f manifests/portal/
	@kubectl -n $(NAMESPACE) rollout restart deploy/portal 2>/dev/null || true
	@kubectl -n $(NAMESPACE) rollout status deploy/portal --timeout=60s
	@echo "portal http://portal.localhost:8081/   (needs /etc/hosts line)"

traffic: ## Run external traffic against both hostnames (requires `hey`)
	$(SHOW) "hey load on nginx + envoy"
	@command -v hey >/dev/null || { echo "install hey: brew install hey"; exit 1; }
	@( hey -z 30m -c 10 -q 20 http://nginx-demo.localhost:8081/ >/dev/null & echo $$! > /tmp/hey-nginx.pid )
	@( hey -z 30m -c 10 -q 20 http://envoy-demo.localhost:8082/ >/dev/null & echo $$! > /tmp/hey-envoy.pid )
	@echo "load started. stop with: make traffic-stop"

traffic-stop: ## Stop HOST hey load generators (does NOT stop the in-cluster loadgen Deployment)
	@[ -f /tmp/hey-nginx.pid ] && kill $$(cat /tmp/hey-nginx.pid) 2>/dev/null || true
	@[ -f /tmp/hey-envoy.pid ] && kill $$(cat /tmp/hey-envoy.pid) 2>/dev/null || true
	@pkill -f "^hey -z" 2>/dev/null || true
	@rm -f /tmp/hey-*.pid
	@echo "hey stopped (in-cluster loadgen still running — use 'make traffic-stop-all' to stop it too)"

traffic-stop-all: traffic-stop ## Stop hey AND the in-cluster loadgen Deployment
	@kubectl -n $(NAMESPACE) scale deploy/loadgen --replicas=0
	@echo "loadgen scaled to 0 — both Grafana panels will go flat after the next rate() window"

traffic-resume: ## Restart the in-cluster loadgen (back to 1 replica)
	@kubectl -n $(NAMESPACE) scale deploy/loadgen --replicas=1
	@kubectl -n $(NAMESPACE) rollout status deploy/loadgen --timeout=60s
	@echo "loadgen resumed"

traffic-status: ## Show what's currently sending traffic
	@echo "=== HOST hey processes ==="
	@pgrep -af "^hey -z" || echo "(none)"
	@echo
	@echo "=== in-cluster loadgen ==="
	@kubectl get deploy/loadgen -n $(NAMESPACE) -o custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas,AGE:.metadata.creationTimestamp
	@echo
	@echo "=== current scrape rate (per ingress) ==="
	@printf "  nginx req/s : "
	@curl -s "http://localhost:9091/api/v1/query?query=sum(rate(nginx_ingress_controller_requests%5B1m%5D))" | python3 -c "import sys,json; r=json.load(sys.stdin)['data']['result']; print(round(float(r[0]['value'][1]),1) if r else 'no data')" 2>/dev/null
	@printf "  envoy req/s : "
	@curl -s "http://localhost:9091/api/v1/query?query=sum(rate(envoy_cluster_upstream_rq_total%5B1m%5D))" | python3 -c "import sys,json; r=json.load(sys.stdin)['data']['result']; print(round(float(r[0]['value'][1]),1) if r else 'no data')" 2>/dev/null

tunnel: ## Port-forward envoy-edge to host :8082 (k3d serverlb only forwards to one LB)
	$(SHOW) "kubectl port-forward envoy-edge :8082"
	@pkill -f "port-forward.*envoy-edge" 2>/dev/null || true
	@echo "waiting for envoy proxy pod to be Ready..."
	@kubectl wait -n envoy-gateway-system pod \
		-l gateway.envoyproxy.io/owning-gateway-name=eg \
		--for=condition=Ready --timeout=180s >/dev/null
	@kubectl -n envoy-gateway-system wait --for=jsonpath='{.subsets[0].addresses[0].ip}' \
		endpoints/envoy-edge --timeout=60s >/dev/null 2>&1 || true
	@kubectl -n envoy-gateway-system port-forward svc/envoy-edge 8082:80 > /tmp/envoy-tunnel.log 2>&1 & echo $$! > /tmp/envoy-tunnel.pid
	@sleep 3
	@curl -s -o /dev/null -w "envoy-demo.localhost:8082 -> HTTP %{http_code}\n" -H "Host: envoy-demo.localhost" http://localhost:8082/ || echo "tunnel not ready yet, retry: make tunnel"
	@echo "tunnel pid: $$(cat /tmp/envoy-tunnel.pid)  log: /tmp/envoy-tunnel.log"

tunnel-stop: ## Stop the envoy port-forward
	@[ -f /tmp/envoy-tunnel.pid ] && kill $$(cat /tmp/envoy-tunnel.pid) 2>/dev/null || true
	@pkill -f "port-forward.*envoy-edge" 2>/dev/null || true
	@rm -f /tmp/envoy-tunnel.pid
	@echo "tunnel stopped"

envoy-admin: ## Port-forward Envoy proxy admin interface to :19000 (config_dump / clusters / listeners)
	@pkill -f "port-forward.*19000:19000" 2>/dev/null || true
	@POD=$$(kubectl -n envoy-gateway-system get pod -l gateway.envoyproxy.io/owning-gateway-name=eg -o name | head -1); \
		kubectl -n envoy-gateway-system port-forward $$POD 19000:19000 > /tmp/envoy-admin-pf.log 2>&1 & \
		echo $$! > /tmp/envoy-admin-pf.pid
	@sleep 2
	@curl -s -o /dev/null -w "envoy admin :19000 -> HTTP %{http_code}\n" http://localhost:19000/ready
	@echo "try: curl localhost:19000/config_dump  |  /clusters  |  /listeners  |  /stats"

argocd-install: ## Install ArgoCD via Helm (anonymous admin enabled — LOCAL LAB ONLY)
	$(SHOW) "helm install argocd"
	@helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
	@helm repo update >/dev/null
	@helm upgrade --install argocd argo/argo-cd \
		-n argocd --create-namespace \
		--set configs.params."server\.insecure"=true \
		--set 'configs.cm.users\.anonymous\.enabled=true' \
		--set 'configs.cm.server\.x\.frame\.options=' \
		--set 'configs.cm.server\.content\.security\.policy=' \
		--set 'configs.rbac.policy\.default=role:admin' \
		--wait
	@kubectl -n argocd rollout status deploy/argocd-server --timeout=180s
	@echo "ArgoCD UI is open to anonymous admin — never use this config off a local lab."

argocd-app: ## Apply the Application CR (points at this repo's manifests/)
	@kubectl apply -f manifests/argocd/application.yaml
	@kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced \
		application/nginx-to-envoy-lab --timeout=120s || true
	@kubectl -n argocd get application nginx-to-envoy-lab \
		-o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

argocd-ui: ## Port-forward ArgoCD UI to :8083 (anonymous access — no login needed)
	@pkill -f "port-forward.*argocd-server" 2>/dev/null || true
	@kubectl -n argocd port-forward svc/argocd-server 8083:80 > /tmp/argocd-pf.log 2>&1 & \
		echo $$! > /tmp/argocd-pf.pid
	@sleep 2
	@echo
	@echo "ArgoCD UI   http://localhost:8083   (anonymous admin — no login)"
	@open http://localhost:8083 2>/dev/null || xdg-open http://localhost:8083 2>/dev/null || true

argocd-stop: ## Stop the ArgoCD UI port-forward
	@[ -f /tmp/argocd-pf.pid ] && kill $$(cat /tmp/argocd-pf.pid) 2>/dev/null || true
	@pkill -f "port-forward.*argocd-server" 2>/dev/null || true
	@rm -f /tmp/argocd-pf.pid
	@echo "argocd ui port-forward stopped"

argocd: argocd-install argocd-app argocd-ui ## End-to-end: install ArgoCD, apply Application, open UI

grafana: ## Open Grafana
	@open http://localhost:3001 || xdg-open http://localhost:3001 || true
	@echo "Grafana http://localhost:3001  (admin / admin)"

prom: ## Open Prometheus
	@open http://localhost:9091 || xdg-open http://localhost:9091 || true
	@echo "Prometheus http://localhost:9091"

demo: ## Curl both paths to confirm both stacks serve
	$(SHOW) "curl via nginx"
	@curl -s http://nginx-demo.localhost:8081/ | head -c 200; echo
	$(SHOW) "curl via envoy"
	@curl -s http://envoy-demo.localhost:8082/ | head -c 200; echo

status: ## Show controller + gateway + servicemonitor state
	@echo "=== ingress-nginx pods ==="; kubectl -n ingress-nginx get pods
	@echo "=== envoy-gateway pods ==="; kubectl -n envoy-gateway-system get pods
	@echo "=== gateway / httproute ==="; kubectl -n $(NAMESPACE) get gateway,httproute
	@echo "=== servicemonitors ==="; kubectl get servicemonitor -A
	@echo "=== prom targets ==="; echo "open http://localhost:9090/targets"

down: ## Destroy cluster
	$(SHOW) "k3d cluster delete $(CLUSTER)"
	@k3d cluster delete $(CLUSTER) || true

clean: down ## Alias for down

# ───────────────────────────────────────────────────────────────────
# DEMO MODE — scripted progressive steps for live walkthroughs
# Usage flow:   demo-reset  →  demo-step1  →  ...  →  demo-step6
# ───────────────────────────────────────────────────────────────────

NARRATE = @printf '\n\033[1;36m── %s ──\033[0m\n' $(1); printf '\033[2m%s\033[0m\n\n' $(2)

demo-reset: ## DEMO step 0 — reset cluster to "today" (only nginx routing, no Envoy)
	$(call NARRATE,"Step 0: today's state","Tearing down any Envoy Gateway / HTTPRoute. Cluster will show ONLY the nginx ingress.")
	-@kubectl delete -n demo httproute demo-via-envoy 2>/dev/null
	-@kubectl delete -n demo gateway eg 2>/dev/null
	-@kubectl delete gatewayclass eg 2>/dev/null
	-@kubectl delete -n monitoring podmonitor envoy-proxy 2>/dev/null
	-@kubectl delete -n envoy-gateway-system svc envoy-edge 2>/dev/null
	@sleep 3
	@echo
	@echo "Now run:  make demo-step1"

demo-step1: ## DEMO step 1 — show what is in the cluster today (only nginx)
	$(call NARRATE,"Step 1: inventory","Audit command every migration starts with. ONE artefact that drives the whole timeline.")
	@echo '$$ kubectl get ing -A'
	@kubectl get ing -A
	@echo
	@echo '$$ kubectl get ing -A -o yaml | grep -E "nginx.ingress|ingressClassName|host:"'
	@kubectl get ing -A -o yaml | grep -E "nginx.ingress|ingressClassName|host:" || true
	@echo
	@echo "↓ Say: 'Today the cluster has one ingress, ingress-nginx. Two annotations in use."
	@echo "         No Envoy. No Gateway API resources. Standard nginx setup.'"
	@echo
	@echo "Now run:  make demo-step2"

demo-step2: ## DEMO step 2 — deploy Envoy Gateway alongside nginx (parallel stack)
	$(call NARRATE,"Step 2: deploy Envoy parallel","Apply GatewayClass + Gateway + HTTPRoute + stable Service — same backend; new ingress path.")
	@echo '$$ kubectl apply -f manifests/envoy/'
	@kubectl apply -f manifests/envoy/
	@echo
	@echo "waiting for envoy proxy pod..."
	@kubectl -n envoy-gateway-system wait pod -l gateway.envoyproxy.io/owning-gateway-name=eg \
		--for=condition=Ready --timeout=180s
	@echo
	@$(MAKE) -s tunnel
	@echo
	@echo "↓ Say: 'Three K8s objects — GatewayClass, Gateway, HTTPRoute. Same backend Service."
	@echo "         Envoy proxy is now serving on envoy-demo.localhost, nginx still serving everyone else.'"
	@echo
	@echo "Now run:  make demo-step3"

demo-step3: ## DEMO step 3 — prove both paths serve the same backend
	$(call NARRATE,"Step 3: side by side","Same backend response from two different ingresses.")
	@echo '$$ curl -H "Host: nginx-demo.localhost" http://localhost:8081/'
	@curl -s -H "Host: nginx-demo.localhost" http://localhost:8081/ | head -c 200; echo
	@echo
	@echo '$$ curl -H "Host: envoy-demo.localhost" http://localhost:8082/'
	@curl -s -H "Host: envoy-demo.localhost" http://localhost:8082/ | head -c 200; echo
	@echo
	@echo "↓ Say: 'Same backend, different proxy. Both return 200. Now I can compare them in the dashboard.'"
	@echo
	@echo "Now run:  make demo-step4"

demo-step4: ## DEMO step 4 — open Grafana dashboard (side-by-side RED panels)
	$(call NARRATE,"Step 4: the comparison dashboard","Grafana opens. Blue panels = nginx baseline. Orange = Envoy. Same row = same metric.")
	@open http://localhost:3001/d/nginx-vs-envoy/ingress-migration-nginx-vs-envoy?orgId=1\&theme=light 2>/dev/null \
		|| xdg-open http://localhost:3001/d/nginx-vs-envoy/ 2>/dev/null \
		|| echo "open http://localhost:3001/d/nginx-vs-envoy/ingress-migration-nginx-vs-envoy"
	@echo
	@echo "↓ Say: 'Three rows: rate, errors, latency p99. Blue baseline, orange new path."
	@echo "         The cutover decision is binary — orange tracks blue go forward,"
	@echo "         orange diverges roll back. Stat panels below: xDS sync, healthy endpoints,"
	@echo "         outlier ejections, circuit-breaker overflow — the leading indicators.'"
	@echo
	@echo "Now run:  make demo-step5"

demo-step5: ## DEMO step 5 — show the weighted canary (HTTPRoute backendRefs with weights)
	$(call NARRATE,"Step 5: weighted ramp","HTTPRoute with two backendRefs and weights. This is the native traffic-split.")
	@echo "Current HTTPRoute:"
	@kubectl get httproute -n demo demo-via-envoy -o yaml | grep -A8 "backendRefs:"
	@echo
	@echo "In a real cutover, change weights step by step:"
	@echo "  5% --> 25% --> 50% --> 100%   with SLO gate at each hold."
	@echo "  YAML stays the same shape — just two backendRefs with different weights."
	@echo
	@echo "Example of a 5/95 split (don't apply, just show):"
	@printf "  backendRefs:\n  - name: demo-api\n    port: 80\n    weight: 95\n  - name: demo-api-v2\n    port: 80\n    weight: 5\n"
	@echo
	@echo "↓ Say: 'In Gateway API the split is a first-class field, not an annotation."
	@echo "         No reload, no nginx-canary annotation. Same shape works for v1/v2 app versions"
	@echo "         and for the migration itself when the LB sits in front.'"
	@echo
	@echo "Now run:  make demo-step6   (rollback)"

demo-step6: ## DEMO step 6 — rollback to nginx-only (delete Envoy resources)
	$(call NARRATE,"Step 6: rollback","Delete the Gateway + HTTPRoute. Envoy stops serving. nginx is unaffected.")
	-@kubectl delete -n demo httproute demo-via-envoy
	-@kubectl delete -n demo gateway eg
	@sleep 2
	@echo
	@echo '$$ kubectl get ing,gateway,httproute -A'
	@kubectl get ing,gateway,httproute -A
	@echo
	@echo "↓ Say: 'Two kubectl deletes and we are back to nginx-only. xDS pushes the removal"
	@echo "         to the Envoy proxy in seconds. In production this is L3 in the rollback tree —"
	@echo "         in-cluster pin without touching DNS.'"
	@echo
	@echo "Demo complete. Run 'make demo-step1' to restart, or 'make demo-step2' to re-deploy Envoy."

demo-help: ## DEMO — show the script in order
	@echo "Demo run order (one command per step):"
	@echo "  make demo-reset    # back to 'today' (only nginx)"
	@echo "  make demo-step1    # show inventory + audit command"
	@echo "  make demo-step2    # deploy Envoy parallel"
	@echo "  make demo-step3    # curl both paths"
	@echo "  make demo-step4    # open Grafana side-by-side"
	@echo "  make demo-step5    # explain weighted ramp YAML"
	@echo "  make demo-step6    # rollback (delete Envoy)"
