#!/bin/bash

# Renders every kustomize overlay and every platform chart, and writes one
# file per resource into a folder.
#
# Usage: render-all.sh <output folder>
#
# Layout of the output:
#   <output folder>/overlay__<app>__<env>/<namespace>__<Kind>__<name>.yml
#   <output folder>/chart__<chart>__<env>/<namespace>__<Kind>__<name>.yml
#
# If a render fails, its folder holds a file called RENDER_FAILED with the
# error text instead of resources.
#
# By default it renders the repo these scripts live in. Set REPO_ROOT to
# render another checkout.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$VALIDATE_DIR/render-lib.sh"

output_root="${1:?Usage: render-all.sh <output folder>}"
rendered_file="$WORK_DIR/rendered.yaml"

# Called after a render. Splits the result into resources, or records the error.
# Usage: store_result <render exit code> <group name>
store_result() {
    local render_exit_code="$1"
    local group="$2"
    local group_dir="$output_root/$group"

    if [ "$render_exit_code" -eq 0 ]; then
        split_into_resources "$rendered_file" "$group_dir"
    else
        mkdir -p "$group_dir"
        cp "$RENDER_ERROR_FILE" "$group_dir/RENDER_FAILED"
    fi
}

# Kustomize overlays: apps/<app>/envs/<env>
for overlay in $(list_overlays); do
    env=$(basename "$overlay")
    app=$(basename "$(dirname "$(dirname "$overlay")")")

    render_overlay "$overlay" "$rendered_file"
    store_result $? "overlay__${app}__${env}"
done

# Helm charts. Each line is "<appset file> <env>".
mapfile -t charts < <(list_charts)

for chart in "${charts[@]}"; do
    read -r appset_file env <<< "$chart"
    chart=$(chart_name "$appset_file")

    render_chart "$appset_file" "$env" "$rendered_file"
    store_result $? "chart__${chart}__${env}"
done
