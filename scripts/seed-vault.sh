#!/bin/bash

# Seeds the homelab dev-mode Vault with every secret the cluster needs.
# Values come from scripts/vault-seed.env (gitignored). Copy
# scripts/vault-seed.example.env to that name and fill it in.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${VAULT_SEED_ENV_FILE:-$SCRIPT_DIR/vault-seed.env}"

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}Missing $ENV_FILE${NC}"
    echo -e "Copy ${CYAN}scripts/vault-seed.example.env${NC} to ${CYAN}scripts/vault-seed.env${NC} and fill it in."
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

REQUIRED_VARS=(
    DB_HOST DB_PORT DB_USER DB_PASS DB_DATABASE
    JWT_SECRET
    CERT_MANAGER_ACCESS_KEY_ID CERT_MANAGER_SECRET_ACCESS_KEY
)
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}$var is empty or missing in $ENV_FILE${NC}"
        exit 1
    fi
done

vault_put() {
    local path="$1"
    shift
    kubectl exec -n vault vault-0 -- vault kv put "$path" "$@" > /dev/null
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to seed $path${NC}"
        exit 1
    fi
    echo -e "${GREEN}Seeded $path${NC}"
}

echo -e "${CYAN}Seeding Vault from $ENV_FILE...${NC}"

vault_put secret/db \
    db-host="$DB_HOST" \
    db-port="$DB_PORT" \
    db-user="$DB_USER" \
    db-pass="$DB_PASS" \
    db-database="$DB_DATABASE"

vault_put secret/jwt \
    jwt-secret="$JWT_SECRET"

vault_put secret/cert-manager-user \
    access-key-id="$CERT_MANAGER_ACCESS_KEY_ID" \
    secret-access-key="$CERT_MANAGER_SECRET_ACCESS_KEY"
