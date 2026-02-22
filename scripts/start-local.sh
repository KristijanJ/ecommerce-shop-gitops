#!/bin/bash

# Get the script's directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Cluster name
CLUSTER_NAME="ecommerce-shop-cluster"

echo -e "${BOLD}${CYAN}========================================${NC}"
echo -e "${BOLD}${CYAN}  Starting Local E-commerce Environment${NC}"
echo -e "${BOLD}${CYAN}========================================${NC}\n"

# ------------------------------------------
# Step 1: Create Kind cluster
# ------------------------------------------
echo -e "${BOLD}${BLUE}[1/9] Creating Kind Cluster...${NC}"
"$SCRIPT_DIR/kind-cluster.sh" create
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to create kind cluster${NC}"
    exit 1
fi
echo ""

# Wait a moment for cluster to be ready
echo -e "${CYAN}Waiting for cluster to be ready...${NC}"
sleep 5

# ------------------------------------------
# Step 2: Install ArgoCD
# ------------------------------------------
echo -e "${BOLD}${BLUE}[2/9] Installing ArgoCD...${NC}"
"$SCRIPT_DIR/install-argo-cd.sh" kind
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to install ArgoCD${NC}"
    exit 1
fi
echo ""

# Wait for ArgoCD to be ready
echo -e "${CYAN}Waiting for ArgoCD to be ready...${NC}"
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s
if [ $? -ne 0 ]; then
    echo -e "${YELLOW}Warning: ArgoCD pods may not be fully ready. Continuing anyway...${NC}"
fi
echo ""

# ------------------------------------------
# Step 3: Install metrics-server
# ------------------------------------------
echo -e "${BOLD}${BLUE}[3/9] Installing Metrics Server...${NC}"
kubectl apply -f "$SCRIPT_DIR/../argocd/applications/metrics-server.yaml"
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to apply metrics-server application${NC}"
    exit 1
fi

echo -e "${CYAN}Waiting for metrics-server to sync...${NC}"
sleep 10

# Wait for metrics-server to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=metrics-server -n kube-system --timeout=180s 2>/dev/null
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Metrics server is ready!${NC}\n"
else
    echo -e "${YELLOW}Metrics server is still starting (this is normal)${NC}\n"
fi

# ------------------------------------------
# Step 4: Install Traefik Ingress Controller
# ------------------------------------------
echo -e "${BOLD}${BLUE}[4/10] Installing Traefik Ingress Controller...${NC}"
kubectl apply -f "$SCRIPT_DIR/../argocd/applications/traefik.yaml"
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to apply traefik application${NC}"
    exit 1
fi

echo -e "${CYAN}Waiting for Traefik to sync...${NC}"
sleep 20

# Wait for Traefik to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=traefik -n traefik --timeout=180s 2>/dev/null
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Traefik is ready!${NC}\n"
else
    echo -e "${YELLOW}Traefik is still starting (this is normal)${NC}\n"
fi

# ------------------------------------------
# Step 5: Install kube-prometheus-stack
# ------------------------------------------
echo -e "${BOLD}${BLUE}[5/10] Installing Kube Prometheus Stack...${NC}"
kubectl apply -f "$SCRIPT_DIR/../argocd/applications/prometheus-grafana.yaml"
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to apply prometheus-grafana application${NC}"
    exit 1
fi

echo -e "${CYAN}Waiting for kube-prometheus-stack to sync...${NC}"
sleep 20

# Wait for kube-prometheus-stack to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=kube-prometheus-stack -n monitoring --timeout=180s 2>/dev/null
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Kube Prometheus stack is ready!${NC}\n"
else
    echo -e "${YELLOW}Kube Prometheus stack is still starting (this is normal)${NC}\n"
fi

# ------------------------------------------
# Step 5: Install HashiCorp Vault
# ------------------------------------------
echo -e "${BOLD}${BLUE}[6/10] Installing HashiCorp Vault...${NC}"
kubectl apply -f "$SCRIPT_DIR/../argocd/applications/hashicorp-vault.yaml"
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to apply hashicorp-vault application${NC}"
    exit 1
fi

echo -e "${CYAN}Waiting for hashicorp-vault to sync...${NC}"
sleep 20

# Wait for hashicorp-vault to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=vault -n vault --timeout=180s 2>/dev/null
if [ $? -eq 0 ]; then
    echo -e "${GREEN}HashiCorp Vault is ready!${NC}\n"
else
    echo -e "${YELLOW}HashiCorp Vault is still starting (this is normal)${NC}\n"
fi

# ------------------------------------------
# Step 6: Install External Secrets
# ------------------------------------------
echo -e "${BOLD}${BLUE}[7/10] Installing External Secrets...${NC}"
kubectl apply -f "$SCRIPT_DIR/../argocd/applications/external-secrets.yaml"
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to apply external-secrets application${NC}"
    exit 1
fi

echo -e "${CYAN}Waiting for external-secrets to sync...${NC}"
sleep 20

# Wait for external-secrets to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=external-secrets -n external-secrets --timeout=180s 2>/dev/null
if [ $? -eq 0 ]; then
    echo -e "${GREEN}External Secrets is ready!${NC}\n"
else
    echo -e "${YELLOW}External Secrets is still starting (this is normal)${NC}\n"
fi

# ------------------------------------------
# Step 7: Create Vault token secret for ESO
# ------------------------------------------
echo -e "${BOLD}${BLUE}[8/10] Creating Vault token secret for External Secrets...${NC}"
kubectl create secret generic vault-token \
    --from-literal=token=root \
    -n external-secrets \
    --dry-run=client -o yaml | kubectl apply -f -
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to create vault-token secret${NC}"
    exit 1
fi
echo -e "${GREEN}Vault token secret created!${NC}\n"

# ------------------------------------------
# Step 8: Seed Vault
# ------------------------------------------
echo -e "${BOLD}${BLUE}[9/10] Seeding Vault data...${NC}"
echo -e "${CYAN}Waiting for Vault pod to be ready...${NC}"
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault -n vault --timeout=120s
if [ $? -ne 0 ]; then
    echo -e "${RED}Vault pod is not ready, cannot seed secrets${NC}"
    exit 1
fi

echo -e "${BOLD}${BLUE}Seeding Vault with DB credentials...${NC}"
kubectl exec -n vault vault-0 -- vault kv put secret/db \
    db-name=ecommerce \
    db-user=postgres \
    db-pass=postgres \
    db-host="postgresql://postgres:postgres@host.docker.internal:5432/ecommerce?schema=public"
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to seed Vault with DB credentials${NC}"
    exit 1
fi
echo -e "${GREEN}Vault DB credentials seeded!${NC}\n"

echo -e "${BOLD}${BLUE}Seeding Vault with JWT secret...${NC}"
kubectl exec -n vault vault-0 -- vault kv put secret/jwt \
    jwt-secret="my-super-secret-key"
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to seed Vault with JWT secret${NC}"
    exit 1
fi
echo -e "${GREEN}Vault JWT secret seeded!${NC}\n"

# ------------------------------------------
# Step 9: Install Vault Secret Store
# ------------------------------------------
echo -e "${BOLD}${BLUE}[10/10] Installing Vault Secret Store...${NC}"
kubectl apply -f "$SCRIPT_DIR/../argocd/applications/vault-secret-store.yaml"
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to apply vault-secret-store application${NC}"
    exit 1
fi
echo -e "${GREEN}Vault Secret Store applied!${NC}\n"

# ------------------------------------------
# Final instructions
# ------------------------------------------
echo -e "${BOLD}${GREEN}========================================${NC}"
echo -e "${BOLD}${GREEN}  Initial Setup Complete!${NC}"
echo -e "${BOLD}${GREEN}========================================${NC}\n"

echo -e "${BOLD}${YELLOW}⚠️  NEXT STEPS - LOAD DOCKER IMAGES${NC}\n"
echo -e "Before deploying your applications, you need to load your Docker images into the Kind cluster:\n"
echo -e "${CYAN}1. Build your Docker images (if not already built):${NC}"
echo -e "   ${BLUE}docker build -t ecommerce-backend:latest ./path/to/backend${NC}"
echo -e "   ${BLUE}docker build -t ecommerce-frontend:latest ./path/to/frontend${NC}\n"

echo -e "${CYAN}2. Load the images into the Kind cluster:${NC}"
echo -e "   ${BLUE}kind load docker-image ecommerce-backend:latest --name $CLUSTER_NAME${NC}"
echo -e "   ${BLUE}kind load docker-image ecommerce-frontend:latest --name $CLUSTER_NAME${NC}\n"

echo -e "${CYAN}3. After loading images, deploy your applications:${NC}"
echo -e "   ${BLUE}kubectl apply -n argocd -f argocd/applications/backend-prod.yaml${NC}"
echo -e "   ${BLUE}kubectl apply -n argocd -f argocd/applications/frontend-prod.yaml${NC}\n"

echo -e "${BOLD}${CYAN}Useful commands:${NC}"
echo -e "  • View ArgoCD password:"
echo -e "    ${BLUE}kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d && echo${NC}"
echo -e "  • Port-forward ArgoCD UI:"
echo -e "    ${BLUE}kubectl port-forward svc/argocd-server -n argocd 8080:443${NC}"
echo -e "  • View cluster info:"
echo -e "    ${BLUE}kubectl cluster-info --context kind-$CLUSTER_NAME${NC}"
echo -e "  • View all pods:"
echo -e "    ${BLUE}kubectl get pods -A${NC}\n"

echo -e "${GREEN}Happy coding! 🚀${NC}\n"
