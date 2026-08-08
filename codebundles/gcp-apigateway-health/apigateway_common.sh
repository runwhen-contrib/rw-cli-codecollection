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
# Portable date helpers
#
# The runtime image is Linux (GNU date), but these scripts are also exercised by
# .test/offline/run_offline_checks.sh on developer machines, where BSD date has
# no -d. Try GNU form first, fall back to BSD.
# -----------------------------------------------------------------------------

# Epoch seconds -> RFC3339 UTC (e.g. 2026-08-08T12:00:00Z)
apigw_epoch_to_iso8601() {
    local epoch="$1"
    date -u -d "@$epoch" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
        || date -u -r "$epoch" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
        || echo ""
}

# RFC3339 timestamp -> epoch seconds (0 when unparseable)
apigw_iso8601_to_epoch() {
    local ts="$1"
    [ -z "$ts" ] && { echo 0; return; }
    date -u -d "$ts" +%s 2>/dev/null \
        || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "${ts%%.*}Z" +%s 2>/dev/null \
        || date -u -j -f "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" +%s 2>/dev/null \
        || echo 0
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

# -----------------------------------------------------------------------------
# ApiConfig resource-name parsing
#
# An apiConfig reference is a full resource path of the form
#   projects/<project>/locations/global/apis/<api>/configs/<config>
# i.e. 8 segments, where the api id is $6 (== $(NF-2)) and the config id is $8.
# Note $(NF-1) is the literal string "configs", NOT the api id.
# -----------------------------------------------------------------------------

# Print the config id from an apiConfig resource path (or the input unchanged
# when it is already a bare id).
apigw_config_id_from_path() {
    printf '%s' "${1##*/}"
}

# Print the api id from an apiConfig resource path, or empty when the path does
# not carry one (e.g. a bare config id was supplied).
apigw_api_id_from_path() {
    local path="$1"
    case "$path" in
        */apis/*/configs/*)
            # strip everything up to and including /apis/, then everything from /configs/
            local rest="${path#*/apis/}"
            printf '%s' "${rest%%/configs/*}"
            ;;
        *) printf '' ;;
    esac
}

# Print the location id from a resource path of the form
# projects/<project>/locations/<location>/<kind>/<id>, else empty.
apigw_location_from_path() {
    local path="$1"
    case "$path" in
        */locations/*)
            local rest="${path#*/locations/}"
            printf '%s' "${rest%%/*}"
            ;;
        *) printf '' ;;
    esac
}

# Wrapper around gcloud api-gateway api-configs describe that returns the
# OpenAPI spec document for a config as JSON, or "{}" when missing.
#
# The ApiConfig resource carries its specs under `openapiDocuments[].document`,
# where `contents` is a BytesField -- i.e. base64-encoded in JSON output -- and
# the decoded payload is usually YAML (the spec as uploaded), occasionally JSON.
# We therefore decode each document and normalize it to JSON via yq (which
# accepts JSON as valid YAML, so one path handles both). Documents that fail to
# parse are skipped rather than aborting the whole check.
#
# Usage: apigw_get_config_spec <config_name> <api_name>
# Prints a JSON array of decoded spec documents (possibly empty).
apigw_get_config_spec() {
    local config_name="$1"
    local api_name="$2"

    local raw="{}"
    raw=$(gcloud api-gateway api-configs describe "$config_name" \
        --api="$api_name" --project="$GCP_PROJECT_ID" \
        --format="json(openapiDocuments)" 2>/dev/null || echo "{}")

    local docs="[]"
    local b64 decoded
    while IFS= read -r b64; do
        [ -z "$b64" ] && continue
        decoded=$(printf '%s' "$b64" | base64 -d 2>/dev/null || echo "")
        [ -z "$decoded" ] && continue
        # yq -o=json normalizes YAML *and* JSON specs to JSON.
        local as_json
        as_json=$(printf '%s' "$decoded" | yq -o=json '.' 2>/dev/null || echo "")
        [ -z "$as_json" ] && continue
        docs=$(echo "$docs" | jq --argjson d "$as_json" '. += [$d]' 2>/dev/null || echo "$docs")
    done < <(echo "$raw" | jq -r '.openapiDocuments[]?.document.contents // empty' 2>/dev/null)

    echo "$docs"
}

# Print the gateway service account for an ApiConfig. This lives on the
# ApiConfig as `gatewayServiceAccount` -- the Gateway resource has no
# `defaults` field at all.
# Usage: apigw_get_config_service_account <config_name> <api_name>
apigw_get_config_service_account() {
    local config_name="$1"
    local api_name="$2"
    gcloud api-gateway api-configs describe "$config_name" \
        --api="$api_name" --project="$GCP_PROJECT_ID" \
        --format="value(gatewayServiceAccount)" 2>/dev/null || echo ""
}

# Given the decoded spec documents from apigw_get_config_spec (a JSON array,
# though any JSON is accepted), print a newline delimited list of every backend
# address referenced via x-google-backend.address. If the extension is not
# present or the spec is missing, nothing is printed.
apigw_extract_backend_addresses() {
    local spec="$1"
    jq -r '
        [.. | objects | .["x-google-backend"]? // empty | .address? // empty]
        | unique[]
    ' <<< "$spec" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Cloud Run backend resolution
#
# Backend addresses cannot be parsed reliably with a regex: service names may
# contain hyphens (so "<service>-<hash>-<region>" is ambiguous), and Cloud Run
# emits two URL shapes --
#   https://<service>-<hash>-<regioncode>.a.run.app   (original)
#   https://<service>-<hash>.<region>.run.app         (current)
# Instead we resolve the address against the project's actual Cloud Run
# inventory, which is authoritative for both the service name and its region.
# -----------------------------------------------------------------------------

APIGW_CLOUDRUN_CACHE=""

# Print (and memoize) a JSON array of {name, region, url} for every Cloud Run
# service in the project.
apigw_cloudrun_inventory() {
    if [ -n "$APIGW_CLOUDRUN_CACHE" ]; then
        echo "$APIGW_CLOUDRUN_CACHE"
        return 0
    fi
    local raw
    raw=$(gcloud run services list --project="$GCP_PROJECT_ID" \
        --format=json 2>/dev/null || echo "[]")
    APIGW_CLOUDRUN_CACHE=$(echo "$raw" | jq '
        [ .[]? | {
            name:   (.metadata.name // ""),
            region: (.metadata.labels["cloud.googleapis.com/location"] // ""),
            url:    (.status.url // "")
          } | select(.name != "") ]' 2>/dev/null || echo "[]")
    echo "$APIGW_CLOUDRUN_CACHE"
}

# Resolve a backend address to the backing Cloud Run service.
# Prints "<name>\t<region>" when the address matches a service in the project,
# or nothing when it does not (i.e. a dangling or non-Cloud-Run backend).
apigw_cloudrun_resolve_address() {
    local addr="$1"
    # Compare on host only; specs often append a path to the backend address.
    local host="${addr#*://}"
    host="${host%%/*}"
    # `first(...)` rather than `| head -1`: under `set -o pipefail` head can exit
    # before jq finishes and the resulting SIGPIPE would fail the caller.
    apigw_cloudrun_inventory | jq -r --arg host "$host" '
        first(
            .[] | select((.url | sub("^https?://";"") | sub("/.*$";"")) == $host)
            | "\(.name)\t\(.region)"
        ) // empty' 2>/dev/null
}

# True when the address looks like a Cloud Run endpoint at all (used to decide
# whether a failure to resolve means "dangling" or "not our concern").
apigw_is_cloudrun_address() {
    case "${1#*://}" in
        *.a.run.app*|*.run.app*) return 0 ;;
        *) return 1 ;;
    esac
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

    # Gateway service account -> the identity used to reach backends. This is a
    # field of the ApiConfig (`gatewayServiceAccount`); the Gateway resource has
    # no `defaults` field.
    local gateway_sa=""
    gateway_sa=$(apigw_get_config_service_account "$api_config" "$api_name")

    if [ -z "$gateway_sa" ]; then
        # Without an identity there is nothing to check against, and silently
        # returning "no issues" would be a false negative. Surface it instead.
        echo "  WARNING: could not resolve gatewayServiceAccount for config '$api_config' of api '$api_name'; skipping invoker check for gateway '$gateway_name'." >&2
        echo "[]"
        return 0
    fi

    local spec="[]"
    spec=$(apigw_get_config_spec "$api_config" "$api_name")

    local issues="[]"
    local addr
    while IFS= read -r addr; do
        [ -z "$addr" ] && continue
        # Not a Cloud Run backend address; cannot IAM check
        apigw_is_cloudrun_address "$addr" || continue

        # Resolve the backing Cloud Run service against the real inventory.
        local resolved svc region
        resolved=$(apigw_cloudrun_resolve_address "$addr")
        if [ -z "$resolved" ]; then
            # Address looks like Cloud Run but no such service exists. That is a
            # dangling backend, which check_backends.sh reports; nothing to IAM
            # check here.
            continue
        fi
        svc="${resolved%%$'\t'*}"
        region="${resolved##*$'\t'}"

        [ -z "$region" ] && region="${GCP_REGIONS%%,*}"
        [ -z "$region" ] && region="global"

        local policy="{}"
        policy=$(gcloud run services get-iam-policy "$svc" \
            --region="$region" --project="$GCP_PROJECT_ID" \
            --format=json 2>/dev/null || echo "{}")

        local has_invoker
        has_invoker=$(echo "$policy" | jq --arg sa "$gateway_sa" \
            '[.bindings[]? | select(.role=="roles/run.invoker") | .members[]? | select(. == $sa or (.=="serviceAccount:"+$sa))] | length')

        if [ "$has_invoker" = "0" ]; then
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

# Write a task's issues to its own JSON file. `$issues` is already a JSON array
# built by the caller, so it is emitted as-is -- piping it through `jq -s` would
# slurp it into a second array ([[...]]), which makes every consumer read an
# empty result as one issue.
apigw_write_issues() {
    local file="$1"
    local issues="$2"
    if ! echo "$issues" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo "apigw_write_issues: expected a JSON array, got: $issues" >&2
        echo "[]" > "$file"
        return 1
    fi
    echo "$issues" | jq '.' > "$file"
}
