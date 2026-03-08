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
CLUSTER_NAME="default"
DB_HOST=192.168.0.30

echo -e "${BOLD}${CYAN}========================================${NC}"
echo -e "${BOLD}${CYAN}  Starting Homelab E-commerce Environment${NC}"
echo -e "${BOLD}${CYAN}========================================${NC}\n"

# ------------------------------------------
# Step 1: Install ArgoCD
# ------------------------------------------
echo -e "${BOLD}${BLUE}[1/4] Installing ArgoCD...${NC}"
"$SCRIPT_DIR/install-argo-cd.sh" homelab
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to install ArgoCD${NC}"
    exit 1
fi
echo ""
sleep 10

echo -e "${CYAN}Waiting for ArgoCD to be ready...${NC}"
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s
if [ $? -ne 0 ]; then
    echo -e "${YELLOW}Warning: ArgoCD pods may not be fully ready. Continuing anyway...${NC}"
fi
echo ""

# ------------------------------------------
# Step 2: Deploy Platform
# ------------------------------------------
echo -e "${BOLD}${BLUE}[2/4] Deploying Platform...${NC}"
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
# Step 3: Seed Vault
# ------------------------------------------
echo -e "${BOLD}${BLUE}[3/4] Seeding Vault...${NC}"

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
    db-host="postgresql://postgres:postgres@$DB_HOST:5432/ecommerce?schema=public"
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
# Step 4: Deploy Applications
# ------------------------------------------
echo -e "${BOLD}${BLUE}[4/4] Deploying Applications...${NC}"
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

echo -e "${BOLD}${CYAN}Useful commands:${NC}"
echo -e "  • View ArgoCD password:   ${BLUE}make argocd-password${NC}"
echo -e "  • Port-forward ArgoCD UI: ${BLUE}make argocd-ui${NC}"
echo -e "  • Port-forward Vault UI:  ${BLUE}make vault-ui${NC}"
echo -e "  • Port-forward Grafana:   ${BLUE}make grafana-ui${NC}"
echo -e "  • View all pods:          ${BLUE}make pods${NC}\n"

echo -e "${GREEN}Happy coding!${NC}\n"
