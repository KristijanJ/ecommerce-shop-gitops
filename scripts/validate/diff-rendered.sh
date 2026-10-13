#!/bin/bash

# Prints a short report of what a change does to the rendered manifests: which
# resources are added, changed or removed, per app and environment. Unchanged
# apps are only counted.
#
# Usage: diff-rendered.sh [base ref] [head ref]
#
#   base ref  what to compare against (default: origin/main)
#   head ref  what to compare (default: the files in your working folder)
#
# Examples:
#   diff-rendered.sh                                  your working folder vs origin/main
#   diff-rendered.sh origin/main feat/keycloak        a branch vs origin/main
#
# In GitHub Actions the report is also added to the run summary.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# sort and comm have to use the same order, or comm reports unsorted input.
export LC_ALL=C

base_ref="${1:-origin/main}"
head_ref="${2:-}"

base_tree="$WORK_DIR/base-tree"
base_rendered="$WORK_DIR/base-rendered"
head_rendered="$WORK_DIR/head-rendered"

# ------------------------------------------------------------------------------
# Rendering both sides
# ------------------------------------------------------------------------------

# Copy the files of a git ref into a folder, without touching the working folder.
# Usage: extract_ref <ref> <folder>
extract_ref() {
    local ref="$1"
    local folder="$2"

    mkdir -p "$folder"
    git -C "$REPO_ROOT" archive "$ref" | tar -x -C "$folder"
}

# Render the base ref and the head with the same scripts, so a difference can
# only come from the changed files.
render_both_sides() {
    local head_tree="$REPO_ROOT"

    extract_ref "$base_ref" "$base_tree"

    if [ -n "$head_ref" ]; then
        head_tree="$WORK_DIR/head-tree"
        extract_ref "$head_ref" "$head_tree"
    fi

    REPO_ROOT="$base_tree" "$VALIDATE_DIR/render-all.sh" "$base_rendered"
    REPO_ROOT="$head_tree" "$VALIDATE_DIR/render-all.sh" "$head_rendered"
}

# ------------------------------------------------------------------------------
# Report helpers
# ------------------------------------------------------------------------------

# Print the resource files of an app, sorted. Prints nothing if the folder is
# missing, which is the case for an app that is new or removed.
list_resource_files() {
    local app_dir="$1"

    if [ -d "$app_dir" ]; then
        ls -1 "$app_dir" | grep -v '^RENDER_FAILED$' | sort
    fi
}

# Turn a file name into text.
#   default__Deployment__web.yml  ->  Deployment default/web
#   _none__ClusterRole__admin.yml ->  ClusterRole admin
describe_resource() {
    local file_name="${1%.yml}"
    local namespace="${file_name%%__*}"
    local rest="${file_name#*__}"
    local kind="${rest%%__*}"
    local name="${rest#*__}"

    if [ "$namespace" = "_none" ]; then
        echo "$kind $name"
    else
        echo "$kind $namespace/$name"
    fi
}

# Turn an app folder name into a heading.
#   overlay__backend__homelab           ->  backend (homelab)
#   chart__kube-prometheus-stack__aws-prod  ->  kube-prometheus-stack chart (aws-prod)
describe_app() {
    local app_dir_name="$1"
    local type="${app_dir_name%%__*}"
    local rest="${app_dir_name#*__}"
    local name="${rest%%__*}"
    local env="${rest#*__}"

    if [ "$type" = "chart" ]; then
        echo "$name chart ($env)"
    else
        echo "$name ($env)"
    fi
}

# Print a bullet list of resources, with a word such as "added" in front.
# Prints at most DIFF_MAX_LISTED lines and counts the rest.
# Usage: print_resource_list <word> <file with one resource file name per line>
print_resource_list() {
    local change="$1"
    local list_file="$2"
    local total
    local listed=0
    local file_name

    total=$(wc -l < "$list_file")

    while read -r file_name; do
        if [ "$listed" -ge "$DIFF_MAX_LISTED" ]; then
            echo "- ... and $((total - listed)) more"
            break
        fi
        echo "- $change $(describe_resource "$file_name")"
        listed=$((listed + 1))
    done < "$list_file"
}

# Print an expandable diff for each changed resource, up to DIFF_MAX_DIFFS.
# Usage: print_changed_diffs <base app dir> <head app dir> <file with changed file names>
print_changed_diffs() {
    local base_app_dir="$1"
    local head_app_dir="$2"
    local list_file="$3"
    local shown=0
    local file_name
    local diff_output

    while read -r file_name; do
        if [ "$shown" -ge "$DIFF_MAX_DIFFS" ]; then
            echo
            echo "_Diffs of the other $(($(wc -l < "$list_file") - shown)) changed resources are not shown._"
            break
        fi

        # Skip the two header lines of diff. The first changed line is what counts.
        diff_output=$(diff -u "$base_app_dir/$file_name" "$head_app_dir/$file_name" | tail -n +3)

        echo
        echo "<details><summary>$(describe_resource "$file_name")</summary>"
        echo
        echo '```diff'
        echo "$diff_output" | head -n "$DIFF_MAX_LINES"
        if [ "$(echo "$diff_output" | wc -l)" -gt "$DIFF_MAX_LINES" ]; then
            echo "... diff cut after $DIFF_MAX_LINES lines"
        fi
        echo '```'
        echo
        echo "</details>"
        shown=$((shown + 1))
    done < "$list_file"
}

# ------------------------------------------------------------------------------
# The report for one app. Returns 1 if the app has no changes.
# ------------------------------------------------------------------------------

print_app_report() {
    local app_dir_name="$1"
    local base_app_dir="$base_rendered/$app_dir_name"
    local head_app_dir="$head_rendered/$app_dir_name"

    local base_files="$WORK_DIR/base-files.txt"
    local head_files="$WORK_DIR/head-files.txt"
    local added_files="$WORK_DIR/added.txt"
    local removed_files="$WORK_DIR/removed.txt"
    local both_files="$WORK_DIR/both.txt"
    local changed_files="$WORK_DIR/changed.txt"
    local file_name

    # A render that fails is worth a line, even if nothing else changed.
    if [ -f "$head_app_dir/RENDER_FAILED" ]; then
        echo "### $(describe_app "$app_dir_name")"
        echo
        echo "Could not render this app:"
        echo
        echo '```'
        cat "$head_app_dir/RENDER_FAILED"
        echo '```'
        echo
        return 0
    fi

    list_resource_files "$base_app_dir" > "$base_files"
    list_resource_files "$head_app_dir" > "$head_files"

    # comm compares two sorted lists. -13 keeps lines only in the second list,
    # -23 only in the first, -12 in both.
    comm -13 "$base_files" "$head_files" > "$added_files"
    comm -23 "$base_files" "$head_files" > "$removed_files"
    comm -12 "$base_files" "$head_files" > "$both_files"

    # Of the resources that exist on both sides, find the ones that differ.
    : > "$changed_files"
    while read -r file_name; do
        if ! cmp -s "$base_app_dir/$file_name" "$head_app_dir/$file_name"; then
            echo "$file_name" >> "$changed_files"
        fi
    done < "$both_files"

    if [ ! -s "$added_files" ] && [ ! -s "$removed_files" ] && [ ! -s "$changed_files" ]; then
        return 1
    fi

    echo "### $(describe_app "$app_dir_name")"
    echo
    echo "$(wc -l < "$added_files") added, $(wc -l < "$changed_files") changed, $(wc -l < "$removed_files") removed"
    echo

    print_resource_list "added" "$added_files"
    print_resource_list "changed" "$changed_files"
    print_resource_list "removed" "$removed_files"
    print_changed_diffs "$base_app_dir" "$head_app_dir" "$changed_files"
    echo
    return 0
}

# ------------------------------------------------------------------------------
# The whole report
# ------------------------------------------------------------------------------

build_report() {
    local app_dir_name
    local changed_apps=0
    local unchanged_apps=0
    local report_body="$WORK_DIR/report-body.md"
    local all_apps

    # Every app that exists on either side, so new and removed apps count too.
    all_apps=$(
        {
            ls -1 "$base_rendered"
            ls -1 "$head_rendered"
        } | sort -u
    )

    : > "$report_body"
    for app_dir_name in $all_apps; do
        if print_app_report "$app_dir_name" >> "$report_body"; then
            changed_apps=$((changed_apps + 1))
        else
            unchanged_apps=$((unchanged_apps + 1))
        fi
    done

    echo "## Rendered changes"
    echo
    echo "Compared with \`$base_ref\`. Resources and Helm charts are rendered the way ArgoCD builds them."
    echo

    if [ "$changed_apps" -eq 0 ]; then
        echo "No rendered changes in any of the $unchanged_apps apps."
        return
    fi

    echo "Apps with changes: $changed_apps. Unchanged: $unchanged_apps."
    echo
    cat "$report_body"
}

render_both_sides
report=$(build_report)

echo "$report"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "$report" >> "$GITHUB_STEP_SUMMARY"
fi
