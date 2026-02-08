#!/bin/bash

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

main() {
    echo -e "${CYAN}Script is starting...${NC}\n"

    case $1 in
        "kind")
            install_argocd_kind
            ;;
        "eks")
            install_argocd_eks
            ;;
        *)
            echo -e "${RED}Unknown command. Usage: ./install-argo-cd [kind|eks]${NC}"
            ;;
    esac
}

install_argocd_kind() {
    if kind get clusters 2>&1 | grep -q "ecommerce-shop-cluster"; then
        echo -e "${YELLOW}Cluster found, installing ArgoCD...${NC}"
        kubectl create namespace argocd
        kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
        echo -e "${GREEN}ArgoCD installed!${NC}"
    else
        echo -e "${RED}Kind cluster not found, create it using ./kind-cluster.sh create${NC}"
    fi
}

install_argocd_eks() {
    echo -e "${YELLOW}Not yet implemented...${NC}"
}

main "$@"
