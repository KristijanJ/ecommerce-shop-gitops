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
BE_IMAGE="kristijan92/ecommerce-shop-be"
FE_IMAGE="kristijan92/ecommerce-shop-fe"

echo -e "${BOLD}${CYAN}========================================${NC}"
echo -e "${BOLD}${CYAN}  Starting Local E-commerce Environment${NC}"
echo -e "${BOLD}${CYAN}========================================${NC}\n"

# ------------------------------------------
# Prompt for image tags
# ------------------------------------------
read -p "$(echo -e "${CYAN}Backend image tag [1.1.1]: ${NC}")" BE_TAG
BE_TAG="${BE_TAG:-1.1.1}"

read -p "$(echo -e "${CYAN}Frontend image tag [1.1.3]: ${NC}")" FE_TAG
FE_TAG="${FE_TAG:-1.1.3}"
echo ""

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
# Step 5: Load Images
# ------------------------------------------
echo -e "${BOLD}${BLUE}[5/6] Loading images into Kind...${NC}"
make -C "$SCRIPT_DIR/.." load-backend-image BE_TAG="$BE_TAG"
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to load backend image${NC}"
    exit 1
fi

make -C "$SCRIPT_DIR/.." load-frontend-image FE_TAG="$FE_TAG"
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to load frontend image${NC}"
    exit 1
fi
echo ""

# ------------------------------------------
# Step 6: Deploy Applications
# ------------------------------------------
echo -e "${BOLD}${BLUE}[6/6] Deploying Applications...${NC}"
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

echo -e "${BOLD}${YELLOW}⚠️  NEXT STEP - START LOAD BALANCER${NC}\n"
echo -e "Run this in a separate terminal to enable LoadBalancer support:\n"
echo -e "   ${BLUE}make lb${NC}\n"

echo -e "${BOLD}${CYAN}Useful commands:${NC}"
echo -e "  • View ArgoCD password:   ${BLUE}make argocd-password${NC}"
echo -e "  • Port-forward ArgoCD UI: ${BLUE}make argocd-ui${NC}"
echo -e "  • Port-forward Vault UI:  ${BLUE}make vault-ui${NC}"
echo -e "  • Port-forward Grafana:   ${BLUE}make grafana-ui${NC}"
echo -e "  • View all pods:          ${BLUE}make pods${NC}\n"

echo -e "${GREEN}Happy coding!${NC}\n"
