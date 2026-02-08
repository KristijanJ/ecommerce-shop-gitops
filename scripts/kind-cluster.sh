#!/bin/bash

# Get the script's absolute path, following symlinks
SCRIPT_PATH=$(readlink -f "$0")
# Get the directory name from the script's absolute path
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

main() {
    echo -e "${CYAN}Script is starting...${NC}\n"

    case $1 in
        "create")
            create_cluster
            ;;
        "delete")
            delete_cluster
            ;;
        *)
            echo -e "${RED}Unknown command. Usage: ./kind-cluster [create|delete]${NC}"
            ;;
    esac
}

create_cluster() {
    if kind get clusters 2>&1 | grep -q "ecommerce-shop-cluster"; then
        echo -e "${YELLOW}Cluster already exists.${NC}"
    else
        echo -e "${CYAN}Creating cluster...${NC}"
        kind create cluster --config="$SCRIPT_DIR/../kind/cluster.yaml"
        echo -e "${GREEN}Cluster created!${NC}"
    fi
}

delete_cluster() {
    echo -e "${CYAN}Deleting cluster...${NC}"
    kind delete cluster --name ecommerce-shop-cluster
    echo -e "${GREEN}Cluster deleted!${NC}"
}

main "$@"
