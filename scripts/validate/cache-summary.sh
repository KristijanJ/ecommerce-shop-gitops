#!/bin/bash

# Adds one line about the chart cache to the GitHub Actions run summary.
#
# Reads two variables that the actions/cache step provides:
#   PRIMARY_KEY  the key this run looks for
#   MATCHED_KEY  the key of the cache that was restored, empty if none was

CHART_CACHE_DIR="${CHART_CACHE_DIR:-$HOME/.cache/gitops-charts}"

if [ -z "${MATCHED_KEY:-}" ]; then
    result="miss (nothing restored, all charts were downloaded)"
elif [ "$MATCHED_KEY" = "$PRIMARY_KEY" ]; then
    result="hit (exact match)"
else
    result="partial hit (restored an older cache, new charts were downloaded)"
fi

# Each cached chart is one .tgz file.
chart_count=$(find "$CHART_CACHE_DIR" -name '*.tgz' 2>/dev/null | wc -l)
cache_size=$(du -sh "$CHART_CACHE_DIR" 2>/dev/null | cut -f1)

line="Chart cache: $result. $chart_count charts, ${cache_size:-0} on disk."

echo "$line"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo
        echo "$line"
    } >> "$GITHUB_STEP_SUMMARY"
fi
