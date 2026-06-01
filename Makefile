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

up: cluster image install-monitoring install-nginx install-envoy apply tunnel ## End-to-end bootstrap (includes envoy host:8082 tunnel)

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

traffic-stop: ## Stop background load generators
	@[ -f /tmp/hey-nginx.pid ] && kill $$(cat /tmp/hey-nginx.pid) 2>/dev/null || true
	@[ -f /tmp/hey-envoy.pid ] && kill $$(cat /tmp/hey-envoy.pid) 2>/dev/null || true
	@rm -f /tmp/hey-*.pid
	@echo "load stopped"

tunnel: ## Port-forward envoy-edge to host :8082 (k3d serverlb only forwards to one LB)
	$(SHOW) "kubectl port-forward envoy-edge :8082"
	@pkill -f "port-forward.*envoy-edge" 2>/dev/null || true
	@kubectl -n envoy-gateway-system port-forward svc/envoy-edge 8082:80 > /tmp/envoy-tunnel.log 2>&1 & echo $$! > /tmp/envoy-tunnel.pid
	@sleep 2
	@curl -s -o /dev/null -w "envoy-demo.localhost:8082 -> HTTP %{http_code}\n" -H "Host: envoy-demo.localhost" http://localhost:8082/ || echo "tunnel not ready yet, retry: make tunnel"
	@echo "tunnel pid: $$(cat /tmp/envoy-tunnel.pid)  log: /tmp/envoy-tunnel.log"

tunnel-stop: ## Stop the envoy port-forward
	@[ -f /tmp/envoy-tunnel.pid ] && kill $$(cat /tmp/envoy-tunnel.pid) 2>/dev/null || true
	@pkill -f "port-forward.*envoy-edge" 2>/dev/null || true
	@rm -f /tmp/envoy-tunnel.pid
	@echo "tunnel stopped"

argocd-install: ## Install ArgoCD via Helm
	$(SHOW) "helm install argocd"
	@helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
	@helm repo update >/dev/null
	@helm upgrade --install argocd argo/argo-cd \
		-n argocd --create-namespace \
		--set configs.params."server\.insecure"=true \
		--wait
	@kubectl -n argocd rollout status deploy/argocd-server --timeout=180s

argocd-app: ## Apply the Application CR (points at this repo's manifests/)
	@kubectl apply -f manifests/argocd/application.yaml
	@kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced \
		application/nginx-to-envoy-lab --timeout=120s || true
	@kubectl -n argocd get application nginx-to-envoy-lab \
		-o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

argocd-ui: ## Port-forward ArgoCD UI to :8083 + print admin password
	@pkill -f "port-forward.*argocd-server" 2>/dev/null || true
	@kubectl -n argocd port-forward svc/argocd-server 8083:80 > /tmp/argocd-pf.log 2>&1 & \
		echo $$! > /tmp/argocd-pf.pid
	@sleep 2
	@echo
	@echo "ArgoCD UI   http://localhost:8083"
	@echo "user:       admin"
	@printf "password:   "
	@kubectl -n argocd get secret argocd-initial-admin-secret \
		-o jsonpath='{.data.password}' | base64 -d; echo

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
