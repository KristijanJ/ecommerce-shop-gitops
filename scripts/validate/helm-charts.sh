#!/bin/bash

# Renders every Helm chart that the platform ApplicationSets deploy, with the
# same chart version and values file that ArgoCD uses, and checks the result
# with kubeconform.
#
# Each ApplicationSet in argocd/appSets/platform holds the chart name, repo and
# version, the values file pattern and the list of environments it deploys to.
# render-lib.sh reads them.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$VALIDATE_DIR/render-lib.sh"

start_check "Helm charts"

rendered_file="$WORK_DIR/rendered.yaml"

# Each line is "<appset file> <env>". Read them all first, because helm and
# kubeconform would otherwise read the rest of the list from stdin.
mapfile -t charts < <(list_charts)

for chart in "${charts[@]}"; do
    read -r appset_file env <<< "$chart"
    name=$(describe_chart "$appset_file" "$env")

    # Step 1: render the chart. A wrong version, a missing values file or a
    # bad value stops here.
    if ! render_chart "$appset_file" "$env" "$rendered_file"; then
        report_fail "$name" "$(cat "$RENDER_ERROR_FILE")"
        continue
    fi

    # Step 2: check the rendered manifests against the schemas.
    validate_with_kubeconform "$name" "$rendered_file"
done

finish_check
