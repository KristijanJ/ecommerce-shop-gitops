#!/bin/bash

# Scans the git history for committed secrets with gitleaks.
#
# This reads only what git has stored. Files that are not committed, like
# scripts/vault-seed.env, are never read. --verbose prints each finding with
# its file and rule, and --redact keeps the secret value out of that output.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

start_check "Secret scan"

if output=$(gitleaks git "$REPO_ROOT" --no-banner --verbose --redact 2>&1); then
    report_ok "no secrets found in the git history"
else
    report_fail "gitleaks found something" "$output"
fi

finish_check
