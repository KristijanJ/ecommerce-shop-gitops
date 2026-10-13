#!/bin/bash

# Renders every Helm chart that the platform ApplicationSets deploy, with the
# same chart version and values file that ArgoCD uses, and checks the result
# with kubeconform.
#
# Each ApplicationSet in argocd/appSets/platform holds everything needed:
#   - the chart name, repo and version
#   - the release name and namespace
#   - the values file pattern (values.<env>.yaml)
#   - the list of environments it deploys to

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

start_check "Helm charts"

# Read one field from an ApplicationSet file.
# Usage: read_field <file> <yq expression>
read_field() {
    local file="$1"
    local expression="$2"

    yq "$expression" "$file"
}

# Turn the values path from the ApplicationSet into a real file path.
# The ApplicationSet has: $values/argocd/.../values.{{metadata.labels.env}}.yaml
# $values is the repo root, and the {{...}} part is the environment name.
resolve_values_file() {
    local pattern="$1"
    local env="$2"
    local path="$pattern"

    path="${path/\$values/$REPO_ROOT}"
    path="${path/\{\{metadata.labels.env\}\}/$env}"

    echo "$path"
}

for appset_file in "$REPO_ROOT"/argocd/appSets/platform/*.yaml; do
    chart=$(read_field "$appset_file" '.spec.template.spec.sources[0].chart')
    chart_repo=$(read_field "$appset_file" '.spec.generators[0].clusters.values.repoURL')
    chart_version=$(read_field "$appset_file" '.spec.generators[0].clusters.values.targetRevision')
    release_name=$(read_field "$appset_file" '.spec.template.spec.sources[0].helm.releaseName')
    namespace=$(read_field "$appset_file" '.spec.template.spec.destination.namespace')
    values_pattern=$(read_field "$appset_file" '.spec.template.spec.sources[0].helm.valueFiles[0]')
    appset_envs=$(read_field "$appset_file" '.spec.generators[0].clusters.selector.matchExpressions[0].values[]')

    # A repo URL that starts with http is a normal Helm repo.
    # Anything else (quay.io/jetstack/charts) is an OCI registry.
    if [[ "$chart_repo" == http* ]]; then
        chart_source=("$chart" --repo "$chart_repo")
    else
        chart_source=("oci://$chart_repo/$chart")
    fi

    for env in $appset_envs; do
        # Skip environments we do not validate (local).
        if [[ " $ENVIRONMENTS " != *" $env "* ]]; then
            continue
        fi

        name="$chart $chart_version ($env)"
        values_file=$(resolve_values_file "$values_pattern" "$env")
        rendered_file="$WORK_DIR/rendered.yaml"
        error_file="$WORK_DIR/render-error.txt"

        # The ApplicationSet lists this env, so ArgoCD will look for the file.
        if [ ! -f "$values_file" ]; then
            report_fail "$name" "Values file not found: ${values_file#"$REPO_ROOT"/}"
            continue
        fi

        # Step 1: render the chart. A wrong version or a bad value stops here.
        if ! helm template "$release_name" "${chart_source[@]}" \
            --version "$chart_version" \
            --namespace "$namespace" \
            --kube-version "$KUBERNETES_VERSION" \
            --values "$values_file" \
            > "$rendered_file" 2> "$error_file"; then
            report_fail "$name" "$(cat "$error_file")"
            continue
        fi

        # Step 2: check the rendered manifests against the schemas.
        validate_with_kubeconform "$name" "$rendered_file"
    done
done

finish_check
