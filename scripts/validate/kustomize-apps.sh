#!/bin/bash

# Renders every kustomize overlay under apps/ and checks the result with
# kubeconform. This is what ArgoCD builds for the backend, the frontend and
# the infrastructure apps.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$VALIDATE_DIR/render-lib.sh"

start_check "Kustomize overlays"

rendered_file="$WORK_DIR/rendered.yaml"

for overlay in $(list_overlays); do
    name="${overlay#"$REPO_ROOT"/}"

    # Step 1: build the overlay. A broken kustomization stops here.
    if ! render_overlay "$overlay" "$rendered_file"; then
        report_fail "$name" "$(cat "$RENDER_ERROR_FILE")"
        continue
    fi

    # Step 2: check the rendered manifests against the schemas.
    validate_with_kubeconform "$name" "$rendered_file"
done

finish_check
