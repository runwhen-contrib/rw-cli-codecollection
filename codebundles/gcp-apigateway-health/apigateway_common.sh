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
# Service Usage / Cloud Run REST APIs.
#
# Returns non-zero when no token can be obtained. It deliberately does NOT print
# an empty string on failure: an empty token is not a usable value, and callers
# that merely tested for emptiness either skipped their entire check in silence
# or reported "cannot authenticate" as a gateway *issue* -- which scores the
# dimension as unhealthy when the truth is that it could not be measured.
apigw_get_access_token() {
    local token
    if ! token=$(gcloud auth print-access-token 2>/dev/null) || [ -z "$token" ]; then
        return 1
    fi
    printf '%s' "$token"
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
    # Three dialects: GNU (-d), BSD (-j -f), BusyBox (-D fmt -d). BusyBox
    # matters because it is what a minimal container image ships, and a silent 0
    # is not harmless here -- check_operations.sh compares the result against its
    # lookback cutoff, so every operation would look older than the window and
    # the check would report nothing at all.
    date -u -d "$ts" +%s 2>/dev/null \
        || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "${ts%%.*}Z" +%s 2>/dev/null \
        || date -u -j -f "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" +%s 2>/dev/null \
        || date -u -D "%Y-%m-%dT%H:%M:%SZ" -d "${ts%%.*}Z" +%s 2>/dev/null \
        || echo 0
}

# -----------------------------------------------------------------------------
# Inventory
# -----------------------------------------------------------------------------

# Load the discovery inventory written by discover_apigateway.sh.
#
# There is deliberately NO empty-inventory fallback. discover_apigateway.sh
# always writes this file -- including when it finds nothing -- so a missing
# file means discovery never ran. Substituting an empty inventory in that case
# makes every check iterate nothing, report zero issues and score as perfectly
# healthy, which is precisely how a broken project reads as clean. Fail loudly
# instead.
apigw_load_inventory() {
    if [ ! -f "apigateway_inventory.json" ]; then
        echo "apigw_load_inventory: apigateway_inventory.json not found -- discover_apigateway.sh must run before this check." >&2
        echo "Refusing to continue: an empty inventory would make this check report zero issues (i.e. healthy) regardless of the real state." >&2
        return 1
    fi
    cat "apigateway_inventory.json"
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

    # --view=FULL is REQUIRED. The default BASIC view "does not include
    # configuration source files", i.e. openapiDocuments is omitted entirely --
    # so without it this returns no documents, no backend addresses are
    # extracted, and both the invoker and backend checks silently report zero
    # issues for every gateway.
    # Do NOT fall back to "{}" here. That yields zero backend addresses, so the
    # per-backend loops in the invoker and backend checks never execute and the
    # gateway is skipped in silence -- the same shape as the BASIC-view bug,
    # reached through a transient error instead of a missing flag.
    local raw
    if ! raw=$(gcloud api-gateway api-configs describe "$config_name" \
            --api="$api_name" --project="$GCP_PROJECT_ID" --view=FULL \
            --format="json(openapiDocuments)" 2>/dev/null); then
        echo "  ERROR: could not describe ApiConfig '$config_name' of api '$api_name'." >&2
        echo "  Cannot determine its backends; refusing to report zero findings for a config that was never read." >&2
        return 1
    fi

    local docs="[]"
    local b64 decoded as_json
    while IFS= read -r b64; do
        [ -z "$b64" ] && continue
        # A document that EXISTS but will not decode or parse is a failure, not
        # an absence. Skipping it silently drops every backend it declares.
        # (No documents at all is legitimate -- e.g. a gRPC-only ApiConfig --
        # and is handled by the loop simply not running.)
        if ! decoded=$(printf '%s' "$b64" | base64 -d 2>/dev/null) || [ -z "$decoded" ]; then
            echo "  ERROR: ApiConfig '$config_name' has a spec document that could not be base64-decoded." >&2
            return 1
        fi
        # yq -o=json normalizes YAML *and* JSON specs to JSON.
        if ! as_json=$(printf '%s' "$decoded" | yq -o=json '.' 2>/dev/null) || [ -z "$as_json" ]; then
            echo "  ERROR: ApiConfig '$config_name' has a spec document that is neither valid YAML nor JSON." >&2
            return 1
        fi
        if ! docs=$(echo "$docs" | jq --argjson d "$as_json" '. += [$d]' 2>/dev/null); then
            echo "  ERROR: could not assemble the decoded spec documents for ApiConfig '$config_name'." >&2
            return 1
        fi
    done < <(echo "$raw" | jq -r '.openapiDocuments[]?.document.contents // empty' 2>/dev/null)

    echo "$docs"
}

# Normalize a service account identifier to the bare form used in IAM policy
# members.
#
# gatewayServiceAccount is documented as "either the Service Account's email
# (`{ACCOUNT_ID}@{PROJECT}.iam.gserviceaccount.com`) or its full resource name
# (`projects/{PROJECT}/accounts/{UNIQUE_ID}`)", and real GCP returns the path
# form (`projects/-/serviceAccounts/{EMAIL}`) for a dedicated SA. IAM policy
# members are always `serviceAccount:{EMAIL}`. Comparing the two formats
# directly reports every correctly-bound gateway as missing its binding.
apigw_normalize_service_account() {
    local sa="$1"
    case "$sa" in
        */serviceAccounts/*|*/accounts/*) printf '%s' "${sa##*/}" ;;
        *)                                printf '%s' "$sa" ;;
    esac
}

# Print the gateway service account for an ApiConfig, normalized to the bare
# email/id form. This lives on the ApiConfig as `gatewayServiceAccount` -- the
# Gateway resource has no `defaults` field at all.
# Usage: apigw_get_config_service_account <config_name> <api_name>
apigw_get_config_service_account() {
    local config_name="$1"
    local api_name="$2"
    # Returns non-zero when the describe itself fails. A config that genuinely
    # has no gatewayServiceAccount returns success with an empty string -- a
    # different fact, handled by the caller. Collapsing the two makes a
    # transient failure look like "no identity configured" and skips the check.
    local raw
    if ! raw=$(gcloud api-gateway api-configs describe "$config_name" \
            --api="$api_name" --project="$GCP_PROJECT_ID" \
            --format="value(gatewayServiceAccount)" 2>/dev/null); then
        return 1
    fi
    apigw_normalize_service_account "$raw"
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

# -----------------------------------------------------------------------------
# Metric scoping
#
# apigateway.googleapis.com/proxy/* is emitted by the Gateway resource itself,
# so it is inherently scoped to API Gateway.
#
# serviceruntime.googleapis.com/api/* is NOT. It is generic Service
# Infrastructure telemetry covering every Google API call in the project --
# compute, container, run, and the bundle's own admin calls all land in it.
# Querying it on metric.type alone measures the whole project: a p95 taken that
# way reflects terraform's API calls, not gateway traffic, and alarms
# permanently in any active project regardless of gateway health.
#
# Every serviceruntime query must therefore be scoped to the managed services
# backing this project's Apis, via the `service` resource label.
# -----------------------------------------------------------------------------

# Print a Cloud Monitoring filter clause restricting a serviceruntime query to
# the managed services in the inventory, e.g.
#   AND resource.label."service" = one_of("a.apigateway...","b.apigateway...")
# Prints nothing when no managed service is known -- callers MUST treat that as
# "cannot scope" and skip the query rather than running it unscoped.
apigw_managed_service_filter() {
    local inventory="$1"
    local list
    list=$(echo "$inventory" | jq -r '
        [ .apis[]?.managedService | select(. != null and . != "") ]
        | unique
        | map("\"" + . + "\"")
        | join(",")' 2>/dev/null || echo "")
    [ -z "$list" ] && { printf ''; return 0; }
    printf ' AND resource.label."service" = one_of(%s)' "$list"
}

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
    # Two distinct outcomes, deliberately handled differently:
    #   query failed        -> cannot determine anything; fail loudly
    #   queried, field empty -> the config genuinely declares no service account
    #                           (the gateway runs as the default identity), so
    #                           there is no binding to verify; warn and skip
    local gateway_sa=""
    if ! gateway_sa=$(apigw_get_config_service_account "$api_config" "$api_name"); then
        echo "  ERROR: could not read ApiConfig '$api_config' of api '$api_name' to resolve the gateway service account." >&2
        echo "  Cannot determine the invoker binding for gateway '$gateway_name'; refusing to report it as clean." >&2
        return 1
    fi

    if [ -z "$gateway_sa" ]; then
        echo "  WARNING: ApiConfig '$api_config' of api '$api_name' declares no gatewayServiceAccount; no identity to verify for gateway '$gateway_name'." >&2
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

        # Do NOT fall back to "{}" here. An empty policy is indistinguishable
        # from "the service has no invoker binding", so a transient API failure
        # would be reported as a confident, wrong "missing roles/run.invoker"
        # against a gateway that actually holds it. "I could not ask" and "the
        # answer is no" must not collapse to the same value.
        local policy
        if ! policy=$(gcloud run services get-iam-policy "$svc" \
                --region="$region" --project="$GCP_PROJECT_ID" \
                --format=json 2>/dev/null); then
            echo "  ERROR: could not read the IAM policy for Cloud Run service '$svc' in region '$region'." >&2
            echo "  Cannot determine whether gateway '$gateway_name' holds roles/run.invoker; refusing to guess." >&2
            return 1
        fi

        local has_invoker
        # A binding satisfies the gateway if it names the service account, or if
        # it opens the service to every principal. `allUsers` covers everyone;
        # `allAuthenticatedUsers` covers every authenticated principal, which a
        # service account is. Treating those as "missing invoker" would be a
        # false positive on any deliberately public backend.
        #
        # Both sides are normalized before comparison: policy members carry a
        # `serviceAccount:` prefix and the gateway identity may arrive as a
        # resource path, so a literal comparison reports correctly-bound
        # gateways as missing. `allUsers`/`allAuthenticatedUsers` survive
        # normalization untouched (no prefix, no slash).
        has_invoker=$(echo "$policy" | jq --arg sa "$gateway_sa" '
            def norm: sub("^[a-zA-Z]+:"; "") | sub(".*/"; "");
            ($sa | norm) as $want
            | [ .bindings[]? | select(.role == "roles/run.invoker") | .members[]?
                | select((. | norm) == $want
                      or . == "allUsers"
                      or . == "allAuthenticatedUsers") ]
            | length')

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
