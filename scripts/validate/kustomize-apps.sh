#!/bin/bash

# Renders every kustomize overlay under apps/ and checks the result with
# kubeconform. This is what ArgoCD builds for the backend, the frontend and
# the infrastructure apps.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

start_check "Kustomize overlays"

for env in $ENVIRONMENTS; do
    # Each app has a folder like apps/backend/envs/homelab
    for overlay in "$REPO_ROOT"/apps/*/envs/"$env"; do
        if [ ! -d "$overlay" ]; then
            continue
        fi

        name="${overlay#"$REPO_ROOT"/}"
        rendered_file="$WORK_DIR/rendered.yaml"
        error_file="$WORK_DIR/render-error.txt"

        # Step 1: build the overlay. A broken kustomization stops here.
        if ! kubectl kustomize "$overlay" > "$rendered_file" 2> "$error_file"; then
            report_fail "$name" "$(cat "$error_file")"
            continue
        fi

        # Step 2: check the rendered manifests against the schemas.
        validate_with_kubeconform "$name" "$rendered_file"
    done
done

finish_check
