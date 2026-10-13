#!/bin/bash

# Shared settings and helper functions for the validation scripts.
# Source this file from a check script. Do not run it directly.

VALIDATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The repo to check. By default it is the repo these scripts live in.
# Set REPO_ROOT to point the scripts at another checkout, for example the
# base commit of a pull request.
REPO_ROOT="${REPO_ROOT:-$(cd "$VALIDATE_DIR/../.." && pwd)}"

# shellcheck disable=SC1091
source "$VALIDATE_DIR/config.env"

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASSED=0
FAILED=0

# Rendered manifests go in this folder. It is removed when the script ends.
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ------------------------------------------------------------------------------
# Reporting
# ------------------------------------------------------------------------------

# Print a heading for one group of checks.
start_check() {
    local title="$1"
    echo -e "${BOLD}${CYAN}${title}${NC}"
}

# In GitHub Actions, add one row to the summary table on the run page.
add_summary_row() {
    local name="$1"
    local result="$2"

    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        echo "| $name | $result |" >> "$GITHUB_STEP_SUMMARY"
    fi
}

report_ok() {
    local name="$1"

    echo -e "  ${GREEN}✓ ${name}${NC}"
    PASSED=$((PASSED + 1))
    add_summary_row "$name" "pass"
}

# The second argument is optional. It holds the error text of the failed tool.
report_fail() {
    local name="$1"
    local details="${2:-}"

    echo -e "  ${RED}✗ ${name}${NC}"
    if [ -n "$details" ]; then
        echo "$details" | sed 's/^/      /'
    fi
    FAILED=$((FAILED + 1))
    add_summary_row "$name" "FAIL"
}

# Print the totals and exit with 1 if anything failed.
finish_check() {
    echo "  $PASSED passed, $FAILED failed"
    echo

    if [ "$FAILED" -gt 0 ]; then
        exit 1
    fi
    exit 0
}

# ------------------------------------------------------------------------------
# kubeconform
# ------------------------------------------------------------------------------

# Check manifest files against the Kubernetes schemas and the CRD catalog.
# -strict rejects fields that the schema does not know.
# -skip leaves out the kinds listed in config.env.
# Usage: validate_with_kubeconform "<name>" <file> [<file> ...]
validate_with_kubeconform() {
    local name="$1"
    shift
    local files=("$@")
    local output

    if output=$(kubeconform \
        -strict \
        -skip "$KUBECONFORM_SKIP_KINDS" \
        -kubernetes-version "$KUBERNETES_VERSION" \
        -schema-location default \
        -schema-location "$CRD_SCHEMA_URL" \
        "${files[@]}" 2>&1); then
        report_ok "$name"
    else
        report_fail "$name" "$output"
    fi
}
