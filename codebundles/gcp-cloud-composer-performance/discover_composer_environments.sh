#!/usr/bin/env bash
set -euo pipefail
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#   GOOGLE_APPLICATION_CREDENTIALS
#
# Discovers all Cloud Composer environments in the GCP project via
# `gcloud composer environments list` and writes a JSON array of environment
# names to OUTPUT_FILE (default composer_environments.json).
#
# If ENV_NAME is set (not "All"), the output is pinned to that single
# environment name.
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
OUTPUT_FILE="${OUTPUT_FILE:-composer_environments.json}"
ENV_NAME="${ENV_NAME:-All}"

if [ "$ENV_NAME" != "All" ] && [ "$ENV_NAME" != "all" ]; then
    jq -n --arg e "$ENV_NAME" '[$e]' > "$OUTPUT_FILE"
    echo "Pinned to environment: ${ENV_NAME}"
    exit 0
fi

if ! envs=$(gcloud composer environments list --project "${GCP_PROJECT_ID}" --format="json" 2>err.log); then
    err=$(cat err.log 2>/dev/null || true)
    rm -f err.log
    echo '[]' > "$OUTPUT_FILE"
    echo "⚠️  Failed to discover Composer environments: ${err}" >&2
    exit 0
fi

names=$(printf '%s' "$envs" | jq -c '[.[] | .name // empty]')
printf '%s' "$names" > "$OUTPUT_FILE"
count=$(printf '%s' "$names" | jq 'length')
echo "Discovered ${count} Cloud Composer environment(s) in ${GCP_PROJECT_ID}"
