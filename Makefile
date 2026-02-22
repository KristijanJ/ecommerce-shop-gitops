# Colors for output
GREEN = \033[0;32m
YELLOW = \033[1;33m
RED = \033[0;31m
CYAN = \033[0;36m
NC = \033[0m # No Color

# Symbols
CHECK="✓"
CROSS="✗"
WARN="⚠"

# Configuration
CLUSTER_NAME = ecommerce-shop-cluster
ARGOCD_NS = argocd
MONITORING_NS = monitoring
BE_IMAGE = kristijan92/ecommerce-shop-be
FE_IMAGE = kristijan92/ecommerce-shop-fe
BE_TAG ?= 1.0.4
FE_TAG ?= 1.1.1

.PHONY: help
help: ## Show this help message
	@echo "$(YELLOW)Available Commands:$(NC)"
	@awk ' \
		BEGIN {FS = ":.*?## "} \
		/^###/ {printf "\n$(YELLOW)%s$(NC)\n", substr($$0, 5); next} \
		/^[a-zA-Z_-]+:.*?## / {printf "  $(GREEN)%-30s$(NC) %s\n", $$1, $$2} \
	' $(MAKEFILE_LIST)
	@echo ""

# ------------------------------------------------------------------------------
### Local development commands:
# ------------------------------------------------------------------------------

.PHONY: check-requirements
check-requirements: ## Check all local development requirements and tool versions
	@./scripts/check-local-requirements.sh

.PHONY: start
start: ## Start the full local environment (cluster + ArgoCD + monitoring)
	@echo "$(CYAN)Starting local environment...$(NC)"
	@./scripts/start-local.sh
	@echo "$(GREEN)$(CHECK) Local environment ready$(NC)"

.PHONY: lb
lb: ## Start cloud-provider-kind for LoadBalancer support (run in a separate terminal, requires sudo)
	@echo "$(YELLOW)$(WARN)  Run this in a dedicated terminal — it stays in the foreground$(NC)"
	@echo "$(CYAN)Docs: https://kind.sigs.k8s.io/docs/user/loadbalancer/$(NC)"
	@sudo $(HOME)/go/bin/cloud-provider-kind

.PHONY: cluster-create
cluster-create: ## Create the Kind cluster
	@echo "$(CYAN)Creating Kind cluster '$(CLUSTER_NAME)'...$(NC)"
	@./scripts/kind-cluster.sh create
	@echo "$(GREEN)$(CHECK) Cluster created$(NC)"

.PHONY: cluster-delete
cluster-delete: ## Delete the Kind cluster
	@echo "$(RED)Deleting Kind cluster '$(CLUSTER_NAME)'...$(NC)"
	@./scripts/kind-cluster.sh delete
	@echo "$(GREEN)$(CHECK) Cluster deleted$(NC)"

.PHONY: cluster-status
cluster-status: ## Show cluster nodes and overall status
	@echo "$(CYAN)Cluster status:$(NC)"
	@kubectl get nodes -o wide

.PHONY: load-backend-image
load-backend-image: ## Load the backend image into Kind (override tag with BE_TAG=x.x.x)
	@echo "$(CYAN)Loading backend image $(BE_IMAGE):$(BE_TAG)...$(NC)"
	kind load docker-image $(BE_IMAGE):$(BE_TAG) --name $(CLUSTER_NAME)
	@echo "$(GREEN)$(CHECK) Backend image loaded$(NC)"

.PHONY: load-frontend-image
load-frontend-image: ## Load the frontend image into Kind (override tag with FE_TAG=x.x.x)
	@echo "$(CYAN)Loading frontend image $(FE_IMAGE):$(FE_TAG)...$(NC)"
	kind load docker-image $(FE_IMAGE):$(FE_TAG) --name $(CLUSTER_NAME)
	@echo "$(GREEN)$(CHECK) Frontend image loaded$(NC)"

# ------------------------------------------------------------------------------
### ArgoCD commands:
# ------------------------------------------------------------------------------

.PHONY: argocd-install
argocd-install: ## Install ArgoCD on the cluster
	@echo "$(CYAN)Installing ArgoCD...$(NC)"
	@./scripts/install-argo-cd.sh kind
	@echo "$(GREEN)$(CHECK) ArgoCD installed$(NC)"

.PHONY: argocd-password
argocd-password: ## Print the initial ArgoCD admin password
	@kubectl -n $(ARGOCD_NS) get secret argocd-initial-admin-secret \
		-o jsonpath="{.data.password}" | base64 -d
	@echo ""

.PHONY: argocd-ui
argocd-ui: ## Port-forward ArgoCD UI to localhost:8080
	@echo "$(CYAN)ArgoCD UI → https://localhost:8080$(NC)"
	@kubectl port-forward svc/argocd-server -n $(ARGOCD_NS) 8080:443

.PHONY: argocd-status
argocd-status: ## Show ArgoCD application sync status
	@kubectl get applications -n $(ARGOCD_NS)

# ------------------------------------------------------------------------------
### Vault commands:
# ------------------------------------------------------------------------------

.PHONY: vault-seed
vault-seed: ## Seed Vault with all secrets (DB credentials + JWT secret)
	@echo "$(CYAN)Seeding Vault with DB credentials...$(NC)"
	@kubectl exec -n vault vault-0 -- vault kv put secret/db \
		db-name=ecommerce \
		db-user=postgres \
		db-pass=postgres \
		db-host="postgresql://postgres:postgres@host.docker.internal:5432/ecommerce?schema=public"
	@echo "$(GREEN)$(CHECK) Vault DB credentials seeded$(NC)"
	@echo "$(CYAN)Seeding Vault with JWT secret...$(NC)"
	@kubectl exec -n vault vault-0 -- vault kv put secret/jwt \
		jwt-secret="my-super-secret-key"
	@echo "$(GREEN)$(CHECK) Vault JWT secret seeded$(NC)"

.PHONY: vault-get
vault-get: ## Read current DB credentials from Vault
	@kubectl exec -n vault vault-0 -- vault kv get secret/db
	@kubectl exec -n vault vault-0 -- vault kv get secret/jwt

.PHONY: vault-ui
vault-ui: ## Port-forward Vault UI to localhost:8200 (token: root)
	@echo "$(CYAN)Vault → http://localhost:8200 (token: root)$(NC)"
	@kubectl port-forward svc/vault -n vault 8200:8200

# ------------------------------------------------------------------------------
### Traefik commands:
# ------------------------------------------------------------------------------

.PHONY: traefik-ui
traefik-ui: ## Port-forward Traefik dashboard to localhost:9000
	@echo "$(CYAN)Traefik dashboard → http://localhost:9000/dashboard/$(NC)"
	@kubectl port-forward svc/traefik-ingress-controller -n traefik 9000:9000

# ------------------------------------------------------------------------------
### Application deployment commands:
# ------------------------------------------------------------------------------

.PHONY: deploy-backend
deploy-backend: ## Deploy the backend ArgoCD application
	@echo "$(CYAN)Deploying backend...$(NC)"
	@kubectl apply -n $(ARGOCD_NS) -f argocd/applications/backend-prod.yaml
	@echo "$(GREEN)$(CHECK) Backend application applied$(NC)"

.PHONY: deploy-frontend
deploy-frontend: ## Deploy the frontend ArgoCD application
	@echo "$(CYAN)Deploying frontend...$(NC)"
	@kubectl apply -n $(ARGOCD_NS) -f argocd/applications/frontend-prod.yaml
	@echo "$(GREEN)$(CHECK) Frontend application applied$(NC)"

.PHONY: deploy-all
deploy-all: deploy-backend deploy-frontend ## Deploy both backend and frontend applications

# ------------------------------------------------------------------------------
### Monitoring commands:
# ------------------------------------------------------------------------------

.PHONY: grafana-ui
grafana-ui: ## Port-forward Grafana UI to localhost:3000 (admin/admin)
	@echo "$(CYAN)Grafana → http://localhost:3000 (admin/admin)$(NC)"
	@kubectl port-forward -n $(MONITORING_NS) svc/kube-prometheus-stack-grafana 3000:80

.PHONY: prometheus-ui
prometheus-ui: ## Port-forward Prometheus UI to localhost:9090
	@echo "$(CYAN)Prometheus → http://localhost:9090$(NC)"
	@kubectl port-forward -n $(MONITORING_NS) svc/kube-prometheus-stack-prometheus 9090:9090

.PHONY: alertmanager-ui
alertmanager-ui: ## Port-forward Alertmanager UI to localhost:9093
	@echo "$(CYAN)Alertmanager → http://localhost:9093$(NC)"
	@kubectl port-forward -n $(MONITORING_NS) svc/kube-prometheus-stack-alertmanager 9093:9093

# ------------------------------------------------------------------------------
### Debugging commands:
# ------------------------------------------------------------------------------

.PHONY: pods
pods: ## Show all pods across all namespaces
	@kubectl get pods -A

.PHONY: logs-backend
logs-backend: ## Tail logs from the backend pods
	@kubectl logs -n prod-backend -l app=ecommerce-be --tail=100 -f

.PHONY: logs-frontend
logs-frontend: ## Tail logs from the frontend pods
	@kubectl logs -n prod-frontend -l app=ecommerce-fe --tail=100 -f

.PHONY: hpa
hpa: ## Show HPA status for all namespaces
	@kubectl get hpa -A

.PHONY: events
events: ## Show recent warning events across all namespaces
	@kubectl get events -A --field-selector=type=Warning --sort-by='.lastTimestamp'

# ------------------------------------------------------------------------------
### Cleanup commands:
# ------------------------------------------------------------------------------

.PHONY: delete-backend
delete-backend: ## Remove the backend ArgoCD application
	@echo "$(RED)Removing backend application...$(NC)"
	@kubectl delete -n $(ARGOCD_NS) -f argocd/applications/backend-prod.yaml
	@echo "$(GREEN)$(CHECK) Backend application removed$(NC)"

.PHONY: delete-frontend
delete-frontend: ## Remove the frontend ArgoCD application
	@echo "$(RED)Removing frontend application...$(NC)"
	@kubectl delete -n $(ARGOCD_NS) -f argocd/applications/frontend-prod.yaml
	@echo "$(GREEN)$(CHECK) Frontend application removed$(NC)"

.PHONY: clean
clean: delete-backend delete-frontend ## Remove all ArgoCD applications

.PHONY: nuke
nuke: cluster-delete ## Destroy the entire local cluster (irreversible)
	@echo "$(GREEN)$(CHECK) Everything torn down$(NC)"
