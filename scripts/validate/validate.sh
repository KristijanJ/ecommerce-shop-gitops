#!/bin/bash

# Runs every validation check, one after the other, and prints a summary.
# This is what `make validate` and the GitHub workflow call.
#
# Each check is its own script in this folder and can be run alone, for
# example: scripts/validate/helm-charts.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# In GitHub Actions, start the table on the run summary page.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "| Check | Result |"
        echo "| --- | --- |"
    } >> "$GITHUB_STEP_SUMMARY"
fi

# Without the tools every other check fails with a confusing error,
# so stop right here if one is missing.
if ! "$VALIDATE_DIR/check-tools.sh"; then
    exit 1
fi

CHECKS=(
    kustomize-apps.sh
    helm-charts.sh
    argocd-manifests.sh
    secrets.sh
)

failed_checks=()

for check in "${CHECKS[@]}"; do
    if ! "$VALIDATE_DIR/$check"; then
        failed_checks+=("$check")
    fi
done

echo -e "${BOLD}${CYAN}Summary${NC}"

if [ "${#failed_checks[@]}" -eq 0 ]; then
    echo -e "  ${GREEN}All checks passed${NC}"
    exit 0
fi

echo -e "  ${RED}Failed:${NC}"
for check in "${failed_checks[@]}"; do
    echo -e "    ${RED}$check${NC}"
done
exit 1
