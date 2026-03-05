#!/usr/bin/env bash
# Shared helper functions for Azure DevOps shell scripts.
# Source this file: source "$(dirname "$0")/_az_helpers.sh"

: "${AZ_RETRY_COUNT:=3}"
: "${AZ_RETRY_INITIAL_WAIT:=5}"
: "${AZ_CMD_TIMEOUT:=30}"

# Run an az CLI command with retry and per-call timeout.
# Usage: az_with_retry az pipelines list --output json
# Returns: sets AZ_RESULT with stdout, returns the exit code
az_with_retry() {
    local attempt=0
    local wait_seconds="$AZ_RETRY_INITIAL_WAIT"
    local exit_code=1

    while [ $attempt -lt "$AZ_RETRY_COUNT" ]; do
        attempt=$((attempt + 1))

        if [ $attempt -gt 1 ]; then
            echo "  Retry attempt $attempt/$AZ_RETRY_COUNT (waiting ${wait_seconds}s)..." >&2
            sleep "$wait_seconds"
            wait_seconds=$((wait_seconds * 2))
        fi

        AZ_RESULT=""
        AZ_RESULT=$(timeout "$AZ_CMD_TIMEOUT" "$@" 2>_az_retry_err.log)
        exit_code=$?

        if [ $exit_code -eq 0 ]; then
            rm -f _az_retry_err.log
            return 0
        fi

        local err_msg
        err_msg=$(cat _az_retry_err.log 2>/dev/null || echo "")
        rm -f _az_retry_err.log

        if [ $exit_code -eq 124 ]; then
            echo "  WARNING: Command timed out after ${AZ_CMD_TIMEOUT}s (attempt $attempt/$AZ_RETRY_COUNT)" >&2
        else
            echo "  WARNING: Command failed with exit code $exit_code (attempt $attempt/$AZ_RETRY_COUNT): $err_msg" >&2
        fi
    done

    echo "  ERROR: Command failed after $AZ_RETRY_COUNT attempts: $*" >&2
    return $exit_code
}

setup_azure_auth() {
    local org_url="https://dev.azure.com/$AZURE_DEVOPS_ORG"

    if ! az extension show --name azure-devops &>/dev/null; then
        echo "Installing Azure DevOps CLI extension..."
        az extension add --name azure-devops --output none
    fi

    az devops configure --defaults organization="$org_url" --output none

    if [ "${AUTH_TYPE:-service_principal}" = "pat" ]; then
        if [ -z "${AZURE_DEVOPS_PAT:-}" ]; then
            echo "ERROR: AZURE_DEVOPS_PAT must be set when AUTH_TYPE=pat"
            exit 1
        fi
        echo "Using PAT authentication..."
        echo "$AZURE_DEVOPS_PAT" | az devops login --organization "$org_url"
    else
        echo "Using service principal authentication..."
    fi
}
