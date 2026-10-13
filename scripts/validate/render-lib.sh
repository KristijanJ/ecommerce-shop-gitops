#!/bin/bash

# Functions that render manifests the way ArgoCD builds them.
# Source this file after lib.sh. The validation checks and the diff report
# both use it, so there is one place that knows how an overlay or a chart is
# rendered.

# When a render fails, the error text of the tool is written to this file.
RENDER_ERROR_FILE="$WORK_DIR/render-error.txt"

# Where to find each setting in a platform ApplicationSet.
CHART_FIELD='.spec.template.spec.sources[0].chart'
CHART_REPO_FIELD='.spec.generators[0].clusters.values.repoURL'
CHART_VERSION_FIELD='.spec.generators[0].clusters.values.targetRevision'
RELEASE_NAME_FIELD='.spec.template.spec.sources[0].helm.releaseName'
NAMESPACE_FIELD='.spec.template.spec.destination.namespace'
VALUES_PATTERN_FIELD='.spec.template.spec.sources[0].helm.valueFiles[0]'
APPSET_ENVS_FIELD='.spec.generators[0].clusters.selector.matchExpressions[0].values[]'

# ------------------------------------------------------------------------------
# Kustomize overlays
# ------------------------------------------------------------------------------

# Print the overlay folders to render, one per line.
# Each app has a folder like apps/backend/envs/homelab
list_overlays() {
    for env in $ENVIRONMENTS; do
        for overlay in "$REPO_ROOT"/apps/*/envs/"$env"; do
            if [ -d "$overlay" ]; then
                echo "$overlay"
            fi
        done
    done
}

# Render one overlay into a file. Returns 1 if the build fails.
# Usage: render_overlay <overlay folder> <output file>
render_overlay() {
    local overlay="$1"
    local output_file="$2"

    kubectl kustomize "$overlay" > "$output_file" 2> "$RENDER_ERROR_FILE"
}

# ------------------------------------------------------------------------------
# Helm charts from the platform ApplicationSets
# ------------------------------------------------------------------------------

# Print "<appset file> <env>" for every chart we render, one pair per line.
# A chart is rendered once for each environment its ApplicationSet lists,
# except environments we do not validate (local).
list_charts() {
    local appset_file
    local appset_envs
    local env

    for appset_file in "$REPO_ROOT"/argocd/appSets/platform/*.yaml; do
        appset_envs=$(yq "$APPSET_ENVS_FIELD" "$appset_file")

        for env in $appset_envs; do
            if [[ " $ENVIRONMENTS " == *" $env "* ]]; then
                echo "$appset_file $env"
            fi
        done
    done
}

# Print the chart name of an ApplicationSet, for example "traefik".
chart_name() {
    local appset_file="$1"

    yq "$CHART_FIELD" "$appset_file"
}

# Print a chart as text, for example "traefik 35.2.0 (homelab)".
describe_chart() {
    local appset_file="$1"
    local env="$2"
    local version

    version=$(yq "$CHART_VERSION_FIELD" "$appset_file")
    echo "$(chart_name "$appset_file") $version ($env)"
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

# Downloaded charts are kept here, one folder per chart and version.
# CI keeps this folder between runs, so a chart is downloaded only once.
CHART_CACHE_DIR="${CHART_CACHE_DIR:-$HOME/.cache/gitops-charts}"

# Download a chart into the cache, unless it is already there, and print the
# path of the chart archive. Returns 1 if the download fails.
# Usage: fetch_chart <chart> <repo> <version>
fetch_chart() {
    local chart="$1"
    local chart_repo="$2"
    local chart_version="$3"
    local chart_dir="$CHART_CACHE_DIR/$chart-$chart_version"

    if ! ls "$chart_dir"/*.tgz > /dev/null 2>&1; then
        mkdir -p "$chart_dir"

        # A repo URL that starts with http is a normal Helm repo.
        # Anything else (quay.io/jetstack/charts) is an OCI registry.
        if [[ "$chart_repo" == http* ]]; then
            helm pull "$chart" --repo "$chart_repo" --version "$chart_version" \
                --destination "$chart_dir" > /dev/null 2> "$RENDER_ERROR_FILE"
        else
            helm pull "oci://$chart_repo/$chart" --version "$chart_version" \
                --destination "$chart_dir" > /dev/null 2> "$RENDER_ERROR_FILE"
        fi

        # Remove the empty folder after a failed download, so the next run tries again.
        if ! ls "$chart_dir"/*.tgz > /dev/null 2>&1; then
            rmdir "$chart_dir"
            return 1
        fi
    fi

    ls "$chart_dir"/*.tgz
}

# Render one chart into a file, with the version and values file that ArgoCD
# uses. Returns 1 if it fails.
# Usage: render_chart <appset file> <env> <output file>
render_chart() {
    local appset_file="$1"
    local env="$2"
    local output_file="$3"

    local chart chart_repo chart_version release_name namespace
    local values_pattern values_file
    local chart_archive

    chart=$(chart_name "$appset_file")
    chart_repo=$(yq "$CHART_REPO_FIELD" "$appset_file")
    chart_version=$(yq "$CHART_VERSION_FIELD" "$appset_file")
    release_name=$(yq "$RELEASE_NAME_FIELD" "$appset_file")
    namespace=$(yq "$NAMESPACE_FIELD" "$appset_file")
    values_pattern=$(yq "$VALUES_PATTERN_FIELD" "$appset_file")
    values_file=$(resolve_values_file "$values_pattern" "$env")

    # The ApplicationSet lists this env, so ArgoCD will look for the file.
    if [ ! -f "$values_file" ]; then
        echo "Values file not found: ${values_file#"$REPO_ROOT"/}" > "$RENDER_ERROR_FILE"
        return 1
    fi

    chart_archive=$(fetch_chart "$chart" "$chart_repo" "$chart_version") || return 1

    helm template "$release_name" "$chart_archive" \
        --namespace "$namespace" \
        --kube-version "$KUBERNETES_VERSION" \
        --values "$values_file" \
        > "$output_file" 2> "$RENDER_ERROR_FILE"
}

# ------------------------------------------------------------------------------
# One file per resource
# ------------------------------------------------------------------------------

# yq expression for the file name of a resource: <namespace>__<Kind>__<name>
# Resources without a namespace get "_none" in its place. A real namespace can
# never contain an underscore, so the two cannot clash. Odd characters in
# names, such as ":" in RBAC names, become "-".
RESOURCE_FILE_NAME='(.metadata.namespace // "_none") + "__" + .kind + "__" + (.metadata.name | sub("[^A-Za-z0-9._-]"; "-"; "g"))'

# Replace every value in the data of Secrets, so no secret value can end up in
# a report. The keys stay, so added and removed keys still show up.
redact_secrets() {
    local resource_dir="$1"
    local secret_file

    for secret_file in "$resource_dir"/*__Secret__*.yml; do
        if [ ! -f "$secret_file" ]; then
            continue
        fi

        yq -i 'with(select(.data); .data |= with_entries(.value = "<redacted>"))' "$secret_file"
        yq -i 'with(select(.stringData); .stringData |= with_entries(.value = "<redacted>"))' "$secret_file"
    done
}

# Split a rendered file into one file per resource inside a folder, and drop
# the kinds listed in DIFF_SKIP_KINDS.
# Usage: split_into_resources <rendered file> <output folder>
split_into_resources() {
    local rendered_file="$1"
    local output_dir="$2"
    local skipped_kind

    mkdir -p "$output_dir"

    # yq writes the files into the current folder, so go there first.
    (cd "$output_dir" && yq --no-doc --split-exp "$RESOURCE_FILE_NAME" "$rendered_file")

    for skipped_kind in $DIFF_SKIP_KINDS; do
        rm -f "$output_dir"/*__"$skipped_kind"__*.yml
    done

    redact_secrets "$output_dir"
}
