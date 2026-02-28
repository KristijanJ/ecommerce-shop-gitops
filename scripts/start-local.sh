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
echo -e "${BOLD}${BLUE}[1/5] Creating Kind Cluster...${NC}"
"$SCRIPT_DIR/kind-cluster.sh" create
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to create kind cluster${NC}"
    exit 1
fi
echo ""

echo -e "${CYAN}Waiting for cluster to be ready...${NC}"
sleep 5

# ------------------------------------------
# Step 2: Install ArgoCD
# ------------------------------------------
echo -e "${BOLD}${BLUE}[2/5] Installing ArgoCD...${NC}"
"$SCRIPT_DIR/install-argo-cd.sh" kind
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to install ArgoCD${NC}"
    exit 1
fi
echo ""

echo -e "${CYAN}Waiting for ArgoCD to be ready...${NC}"
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s
if [ $? -ne 0 ]; then
    echo -e "${YELLOW}Warning: ArgoCD pods may not be fully ready. Continuing anyway...${NC}"
fi
echo ""

# ------------------------------------------
# Step 3: Deploy Platform
# ------------------------------------------
echo -e "${BOLD}${BLUE}[3/5] Deploying Platform...${NC}"
kubectl apply -f "$SCRIPT_DIR/../argocd/bootstrap/01-root-platform.yaml"
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to apply root-platform${NC}"
    exit 1
fi
echo ""

echo -e "${CYAN}Waiting for platform to be ready...${NC}"
echo -e "${CYAN}(This may take a few minutes while Helm charts are pulled and deployed)${NC}\n"

echo -e "${CYAN}Waiting for Vault pod to appear...${NC}"
until kubectl get pods -n vault -l app.kubernetes.io/name=vault 2>/dev/null | grep -q "vault"; do
    sleep 10
done

kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault -n vault --timeout=300s
if [ $? -ne 0 ]; then
    echo -e "${RED}Vault pod is not ready, cannot seed secrets${NC}"
    exit 1
fi

echo -e "${CYAN}Waiting for External Secrets pod to appear...${NC}"
until kubectl get pods -n external-secrets -l app.kubernetes.io/instance=external-secrets 2>/dev/null | grep -q "external-secrets"; do
    sleep 10
done

kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=external-secrets -n external-secrets --timeout=180s
if [ $? -ne 0 ]; then
    echo -e "${YELLOW}Warning: External Secrets may not be fully ready. Continuing anyway...${NC}"
fi
echo ""

# ------------------------------------------
# Step 4: Seed Vault
# ------------------------------------------
echo -e "${BOLD}${BLUE}[4/5] Seeding Vault...${NC}"

echo -e "${CYAN}Creating Vault token secret for External Secrets...${NC}"
kubectl create secret generic vault-token \
    --from-literal=token=root \
    -n external-secrets \
    --dry-run=client -o yaml | kubectl apply -f -
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to create vault-token secret${NC}"
    exit 1
fi
echo -e "${GREEN}Vault token secret created!${NC}\n"

echo -e "${CYAN}Seeding Vault with DB credentials...${NC}"
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

echo -e "${CYAN}Seeding Vault with JWT secret...${NC}"
kubectl exec -n vault vault-0 -- vault kv put secret/jwt \
    jwt-secret="my-super-secret-key"
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to seed Vault with JWT secret${NC}"
    exit 1
fi
echo -e "${GREEN}Vault JWT secret seeded!${NC}\n"

# ------------------------------------------
# Step 5: Deploy Applications
# ------------------------------------------
echo -e "${BOLD}${BLUE}[5/5] Deploying Applications...${NC}"
kubectl apply -f "$SCRIPT_DIR/../argocd/bootstrap/02-root-apps.yaml"
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to apply root-apps${NC}"
    exit 1
fi
echo ""

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

echo -e "${BOLD}${CYAN}Useful commands:${NC}"
echo -e "  • View ArgoCD password:"
echo -e "    ${BLUE}kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d && echo${NC}"
echo -e "  • Port-forward ArgoCD UI:"
echo -e "    ${BLUE}kubectl port-forward svc/argocd-server -n argocd 8080:443${NC}"
echo -e "  • View cluster info:"
echo -e "    ${BLUE}kubectl cluster-info --context kind-$CLUSTER_NAME${NC}"
echo -e "  • View all pods:"
echo -e "    ${BLUE}kubectl get pods -A${NC}\n"

echo -e "${GREEN}Happy coding!${NC}\n"
