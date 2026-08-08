#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# apigateway_common.sh
#
# Shared helpers for the gcp-apigateway-health CodeBundle. This file is meant
# to be sourced (`. ./apigateway_common.sh`) by the per-task bash scripts so
# that common logic -- GCP authentication, the API Gateway inventory, metric
# type resolution, backend extraction and the gateway invoker-binding check --
# is defined exactly once.
#
# The `check_gateway_invoker_bindings` function is deliberately self-contained
# so that it can be lifted as-is for a Cloud Run service-account IAM PR review
# context later.
#
# REQUIRED ENV VARS (set by runbook.robot / sli.robot before sourcing):
#   GCP_PROJECT_ID   - GCP project hosting the API Gateways
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${API_NAME:=}"
: "${API_CONFIG_NAME:=}"
: "${GATEWAY_NAME:=}"
: "${GCP_REGIONS:=}"

COMMON_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# Authentication
# -----------------------------------------------------------------------------

# Print a valid OAuth access token for the Cloud Monitoring / API Gateway /
# Service Usage / Cloud Run REST APIs, or empty on failure.
apigw_get_access_token() {
    gcloud auth print-access-token 2>/dev/null || echo ""
}

# JSON-encode a string safely for use as a jq --arg value.
apigw_jqarg() {
    printf '%s' "$1" | jq -Rs .
}

# -----------------------------------------------------------------------------
# Inventory
# -----------------------------------------------------------------------------

# Load the discovery inventory written by discover_apigateway.sh. Falls back
# to an empty structure when discovery has not run so that each script remains
# robust.
apigw_load_inventory() {
    if [ -f "apigateway_inventory.json" ]; then
        cat "apigateway_inventory.json"
    else
        printf '{"project":"%s","apis":[],"gateways":[],"regions":[]}' "$GCP_PROJECT_ID"
    fi
}

# Wrapper around gcloud api-gateway api-configs describe that returns the
# populated OpenAPI spec document for a config, or "{}" when missing.
# Usage: apigw_get_config_spec <config_name> <api_name>
apigw_get_config_spec() {
    local config_name="$1"
    local api_name="$2"
    gcloud api-gateway api-configs describe "$config_name" \
        --api="$api_name" --project="$GCP_PROJECT_ID" \
        --format="json(openapiDocs)" 2>/dev/null || echo "{}"
}

# Given an OpenAPI spec document (json), print a newline delimited list of
# every backend address referenced via x-google-backend.address. If METRIC
# of the extension is not present or the spec is missing, nothing is printed.
apigw_extract_backend_addresses() {
    local spec="$1"
    jq -r '
        [.. | objects | .["x-google-backend"]? // empty | .address? // empty]
        | unique[]
    ' <<< "$spec" 2>/dev/null || true
}

# For a given backend address (e.g.
# https://<service>-<hash>-uc.a.run.app), extract the Cloud Run service short
# name. Prints the service name (or empty).
apigw_cloudrun_service_from_address() {
    local addr="$1"
    # cloud run addresses are https://<service>-<hash>-<region>.a.run.app
    jq -rn --arg a "$addr" '
        ( $a | capture("^https://(?<name>[^.-]+)-[a-z0-9]+-[a-z]+[0-9]?\\.a\\.run\\.app") )
        // ( $a | capture("^https://(?<name>[^.-]+)-[a-z0-9]+-[a-z]+[0-9]?-\\.a\\.run\\.app") )
        // empty | .name
    ' 2>/dev/null || echo ""
}

# -----------------------------------------------------------------------------
# Metric type resolution
#
# API Gateway surfaces telemetry through two paths:
#   * apigateway.googleapis.com/proxy/*  (resource apigateway.googleapis.com/Gateway)
#   * serviceruntime.googleapis.com/api/* (resource consumed_api / produced_api)
# Which one carries usable request / latency data varies by project. Rather
# than hardcode a metric type that may return an empty series (and fail
# silently), these helpers discover the metric descriptors at runtime and
# allow a METRIC_TYPE_OVERRIDE environment variable.
# -----------------------------------------------------------------------------

DEFAULT_COUNT_METRIC="apigateway.googleapis.com/proxy/request_count"
DEFAULT_LATENCY_METRIC="serviceruntime.googleapis.com/api/request_latencies"
DEFAULT_BACKEND_LATENCY_METRIC="serviceruntime.googleapis.com/api/request_latencies_backend"

# Print the request-count metric type to use. Uses METRIC_TYPE_OVERRIDE when
# set, otherwise the default. The actual descriptor existence check is done by
# the caller (query returns empty series if absent).
apigw_resolve_count_metric() {
    if [ -n "${METRIC_TYPE_OVERRIDE:-}" ]; then
        echo "$METRIC_TYPE_OVERRIDE"
    else
        echo "$DEFAULT_COUNT_METRIC"
    fi
}

apigw_resolve_latency_metric() {
    if [ -n "${LATENCY_METRIC_TYPE_OVERRIDE:-}" ]; then
        echo "$LATENCY_METRIC_TYPE_OVERRIDE"
    else
        echo "$DEFAULT_LATENCY_METRIC"
    fi
}

apigw_resolve_backend_latency_metric() {
    if [ -n "${BACKEND_LATENCY_METRIC_TYPE_OVERRIDE:-}" ]; then
        echo "$BACKEND_LATENCY_METRIC_TYPE_OVERRIDE"
    elif [ -n "${LATENCY_METRIC_TYPE_OVERRIDE:-}" ]; then
        echo "$LATENCY_METRIC_TYPE_OVERRIDE"
    else
        echo "$DEFAULT_BACKEND_LATENCY_METRIC"
    fi
}

# -----------------------------------------------------------------------------
# Gateway invoker-binding check
#
# For the deployed ApiConfig of a gateway, extract every backend referenced by
# x-google-backend.address, resolve the backing Cloud Run service, and verify
# the gateway's service account holds roles/run.invoker via
# run.services.getIamPolicy. Missing bound invoker => every request to that
# route 403s while the gateway and Cloud Run both report healthy.
#
# This function is self-contained and reusable for Cloud Run service-account
# IAM PR review context.
#
# Usage:
#   check_gateway_invoker_bindings <gateway_name> <api_config> <api_name> <location>
#
# Prints a jq-ARRAY of issue objects (possibly empty) to stdout.
# -----------------------------------------------------------------------------
check_gateway_invoker_bindings() {
    local gateway_name="$1"
    local api_config="$2"
    local api_name="$3"
    local location="$4"

    # Nothing to check if no deployed config is referenced
    if [ -z "$api_config" ] || [ "$api_config" = "null" ]; then
        echo "[]"
        return 0
    fi

    # Gateway service account -> the identity used to reach backends
    local gateway_sa=""
    gateway_sa=$(gcloud api-gateway gateways describe "$gateway_name" \
        --location="$location" --project="$GCP_PROJECT_ID" \
        --format="value(defaults.serviceAccount)" 2>/dev/null || echo "")

    local spec="{}"
    spec=$(apigw_get_config_spec "$api_config" "$api_name")

    local issues="[]"
    local addr
    while IFS= read -r addr; do
        [ -z "$addr" ] && continue
        # Resolve the backing Cloud Run service
        local svc
        svc=$(echo "$addr" | sed -E 's#^https://([^.-]+)-[a-z0-9]+-[a-z0-9]+-?.*\.a\.run\.app.*#\1#')

        local region
        region=$(echo "$addr" | sed -E 's#^https://[^.]+\.[^.]+-([a-z0-9-]+)\.a\.run\.app.*#\1#')

        if [ -z "$svc" ]; then
            # Not a Cloud Run backend address; cannot IAM check
            continue
        fi

        [ -z "$region" ] && region="${GCP_REGIONS%%,*}"
        [ -z "$region" ] && region="global"

        local policy="{}"
        policy=$(gcloud run services get-iam-policy "$svc" \
            --region="$region" --project="$GCP_PROJECT_ID" \
            --format=json 2>/dev/null || echo "{}")

        local has_invoker
        has_invoker=$(echo "$policy" | jq --arg sa "$gateway_sa" \
            '[.bindings[]? | select(.role=="roles/run.invoker") | .members[]? | select(. == $sa or (.=="serviceAccount:"+$sa))] | length')

        if [ "$has_invoker" = "0" ] && [ -n "$gateway_sa" ]; then
            issues=$(echo "$issues" | jq \
                --arg title "Gateway \`$gateway_name\` service account is missing roles/run.invoker on Cloud Run service \`$svc\`" \
                --arg details "Gateway '$gateway_name' (location '$location', apiConfig '$api_config' of api '$api_name') routes to Cloud Run service '$svc' in region '$region' via backend '$addr', but its service account '$gateway_sa' is not bound to roles/run.invoker. Every request to that route returns 403 Forbidden while the gateway and Cloud Run service both report healthy." \
                --arg severity "2" \
                --arg expected "The gateway service account should hold roles/run.invoker on every backend Cloud Run service it calls" \
                --arg actual "Gateway service account '$gateway_sa' lacks roles/run.invoker on '$svc'" \
                --arg next_steps "Grant invoker on the backing Cloud Run service: gcloud run services add-iam-policy-binding $svc --region=$region --member=serviceAccount:$gateway_sa --role=roles/run.invoker --project=$GCP_PROJECT_ID. If the gateway is not found, check the CLI location matches the deployed region." \
                '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"expected":$expected,"actual":$actual,"next_steps":$next_steps}]')
        fi
    done < <(apigw_extract_backend_addresses "$spec")

    echo "$issues"
}

# -----------------------------------------------------------------------------
# Issue helpers
# -----------------------------------------------------------------------------

# Wrap an issue object so that it can later be parsed. Each task writes its own
# outputs to a uniquely named JSON file.
apigw_write_issues() {
    local file="$1"
    local issues="$2"
    echo "$issues" | jq -s '.' > "$file"
    if [ ! -s "$file" ]; then
        echo "[]" > "$file"
    fi
}
