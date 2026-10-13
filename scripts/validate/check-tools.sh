#!/bin/bash

# Checks that every tool the validation scripts need is installed.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

start_check "Tools"

REQUIRED_TOOLS=(helm kubectl kubeconform yq gitleaks)

for tool in "${REQUIRED_TOOLS[@]}"; do
    if command -v "$tool" > /dev/null; then
        report_ok "$tool"
    else
        report_fail "$tool is not installed"
    fi
done

if [ "$FAILED" -gt 0 ]; then
    echo "  Install the missing tools with: scripts/validate/install-tools.sh"
    echo "  helm and kubectl have to be installed by hand."
fi

finish_check
