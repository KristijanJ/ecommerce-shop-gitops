#!/bin/bash

# Checks the ArgoCD manifests themselves with kubeconform: the
# ApplicationSets, the root Applications and the cluster Secrets.
# The values files in argocd/appSets/**/values/ are not manifests, so they
# are left out.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

start_check "ArgoCD manifests"

# Collect the files first, so the loop below is easy to read.
manifest_files=()
while IFS= read -r file; do
    manifest_files+=("$file")
done < <(find "$REPO_ROOT/argocd" -name '*.yaml' -not -path '*/values/*' | sort)

# Check one file at a time, so a failure names the file.
for file in "${manifest_files[@]}"; do
    validate_with_kubeconform "${file#"$REPO_ROOT"/}" "$file"
done

finish_check
