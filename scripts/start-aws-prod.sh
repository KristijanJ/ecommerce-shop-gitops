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
CLUSTER_NAME="ecommerce-cluster-prod"
DB_HOST=192.168.0.30

echo -e "${BOLD}${CYAN}============================================${NC}"
echo -e "${BOLD}${CYAN}  Starting AWS PROD E-commerce Environment${NC}"
echo -e "${BOLD}${CYAN}============================================${NC}\n"

# ------------------------------------------
# Confirm kubectl context
# ------------------------------------------
CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null)"
echo -e "${CYAN}Current kubectl context: ${BOLD}${GREEN}${CURRENT_CONTEXT:-none}${NC}"
read -p "$(echo -e "${CYAN}Continue? [y/N]: ${NC}")" CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Aborted${NC}"
    exit 1
fi
read -p "$(echo -e "${CYAN}AWS SSO profile (used for the Route53 records): ${NC}")" AWS_PROFILE
export AWS_PROFILE
echo ""

# ------------------------------------------
# Step 1: Install ArgoCD
# ------------------------------------------
echo -e "${BOLD}${BLUE}[1/4] Installing ArgoCD...${NC}"
"$SCRIPT_DIR/install-argo-cd.sh" aws-prod
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
kubectl apply -f "$SCRIPT_DIR/../argocd/bootstrap/00-cluster-aws-prod.yaml"
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to apply cluster secret${NC}"
    exit 1
fi
kubectl apply -f "$SCRIPT_DIR/../argocd/bootstrap/01-root-platform.yaml"
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to apply root-platform${NC}"
    exit 1
fi
echo ""

echo -e "${CYAN}Waiting for platform to be ready...${NC}"
echo -e "${CYAN}(This may take a few minutes while Helm charts are pulled and deployed)${NC}\n"

kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=external-secrets -n external-secrets --timeout=180s
if [ $? -ne 0 ]; then
    echo -e "${YELLOW}Warning: External Secrets may not be fully ready. Continuing anyway...${NC}"
fi
echo ""

# ------------------------------------------
# Step 4: Deploy Applications
# ------------------------------------------
echo -e "${BOLD}${BLUE}[3/4] Deploying Applications...${NC}"
kubectl apply -f "$SCRIPT_DIR/../argocd/bootstrap/02-root-apps.yaml"
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to apply root-apps${NC}"
    exit 1
fi
echo ""

# ------------------------------------------
# Step 4: Point the domain names at the ALB
# ------------------------------------------
echo -e "${BOLD}${BLUE}[4/4] Creating Route53 records...${NC}"
"$SCRIPT_DIR/route53-alb.sh" upsert
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to create the Route53 records, run: ./scripts/route53-alb.sh upsert${NC}"
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
