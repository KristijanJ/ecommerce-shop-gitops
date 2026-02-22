#!/bin/bash

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Symbols
CHECK="✓"
CROSS="✗"
WARN="⚠"

ERRORS=0
WARNINGS=0

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

pass() {
    echo -e "  ${GREEN}${CHECK} $1${NC}"
}

fail() {
    echo -e "  ${RED}${CROSS} $1${NC}"
    ERRORS=$((ERRORS + 1))
}

warn() {
    echo -e "  ${YELLOW}${WARN}  $1${NC}"
    WARNINGS=$((WARNINGS + 1))
}

check_command() {
    local cmd="$1"
    local label="${2:-$1}"
    local hint="$3"

    if command -v "$cmd" &>/dev/null; then
        local version
        version=$("$cmd" version --short 2>/dev/null \
            || "$cmd" version 2>/dev/null \
            || "$cmd" --version 2>/dev/null \
            | head -1)
        pass "$label  =>  $(echo "$version" | head -1)"
    else
        fail "$label not found${hint:+ — $hint}"
    fi
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

echo -e "${BOLD}${CYAN}========================================${NC}"
echo -e "${BOLD}${CYAN}  Local Development Requirements Check${NC}"
echo -e "${BOLD}${CYAN}========================================${NC}\n"

# --- Required tools -----------------------------------------------------------
echo -e "${BOLD}Required tools:${NC}"

check_command docker    "Docker"   "https://docs.docker.com/get-docker/"
check_command kind      "Kind"     "https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
check_command kubectl   "kubectl"  "https://kubernetes.io/docs/tasks/tools/"
check_command argocd    "ArgoCD CLI" "https://argo-cd.readthedocs.io/en/stable/cli_installation/ (optional but useful)"
check_command k9s       "k9s" "https://k9scli.io/ (optional but useful)"

echo ""

# --- Docker daemon ------------------------------------------------------------
echo -e "${BOLD}Docker daemon:${NC}"
if docker info &>/dev/null; then
    pass "Docker daemon is running"
else
    fail "Docker daemon is not running — start Docker Desktop or the Docker service"
fi

echo ""

# --- Resource recommendations -------------------------------------------------
echo -e "${BOLD}Docker resource recommendations (4-node Kind cluster):${NC}"

# Memory
TOTAL_MEM_BYTES=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
TOTAL_MEM_GB=$(( TOTAL_MEM_BYTES / 1024 / 1024 / 1024 ))
if [ "$TOTAL_MEM_GB" -ge 8 ]; then
    pass "Docker memory: ${TOTAL_MEM_GB}GB (>= 8GB recommended)"
elif [ "$TOTAL_MEM_GB" -ge 6 ]; then
    warn "Docker memory: ${TOTAL_MEM_GB}GB (8GB recommended — some components may be slow)"
elif [ "$TOTAL_MEM_GB" -gt 0 ]; then
    fail "Docker memory: ${TOTAL_MEM_GB}GB (8GB recommended — cluster may not start reliably)"
else
    warn "Could not determine Docker memory limit"
fi

# CPUs
DOCKER_CPUS=$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)
if [ "$DOCKER_CPUS" -ge 4 ]; then
    pass "Docker CPUs: ${DOCKER_CPUS} (>= 4 recommended)"
elif [ "$DOCKER_CPUS" -ge 2 ]; then
    warn "Docker CPUs: ${DOCKER_CPUS} (4 recommended)"
elif [ "$DOCKER_CPUS" -gt 0 ]; then
    fail "Docker CPUs: ${DOCKER_CPUS} (4 recommended)"
else
    warn "Could not determine Docker CPU count"
fi

echo ""

# --- Disk space ---------------------------------------------------------------
echo -e "${BOLD}Disk space:${NC}"
AVAILABLE_KB=$(df -k . | awk 'NR==2 {print $4}')
AVAILABLE_GB=$(( AVAILABLE_KB / 1024 / 1024 ))
if [ "$AVAILABLE_GB" -ge 20 ]; then
    pass "Available disk: ~${AVAILABLE_GB}GB (>= 20GB recommended)"
elif [ "$AVAILABLE_GB" -ge 10 ]; then
    warn "Available disk: ~${AVAILABLE_GB}GB (20GB recommended)"
else
    fail "Available disk: ~${AVAILABLE_GB}GB (20GB recommended — may run out of space)"
fi

echo ""

# --- Kind cluster -------------------------------------------------------------
echo -e "${BOLD}Kind cluster:${NC}"
if kind get clusters 2>/dev/null | grep -q "ecommerce-shop-cluster"; then
    pass "Cluster 'ecommerce-shop-cluster' already exists"
else
    warn "Cluster 'ecommerce-shop-cluster' not found — run 'make cluster-create' or 'make start'"
fi

echo ""

# --- Summary ------------------------------------------------------------------
echo -e "${BOLD}${CYAN}========================================${NC}"
if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
    echo -e "${BOLD}${GREEN}  All checks passed — ready to go!${NC}"
elif [ "$ERRORS" -eq 0 ]; then
    echo -e "${BOLD}${YELLOW}  ${WARNINGS} warning(s) — environment should work but review above${NC}"
else
    echo -e "${BOLD}${RED}  ${ERRORS} error(s), ${WARNINGS} warning(s) — fix errors before continuing${NC}"
fi
echo -e "${BOLD}${CYAN}========================================${NC}\n"

[ "$ERRORS" -eq 0 ]