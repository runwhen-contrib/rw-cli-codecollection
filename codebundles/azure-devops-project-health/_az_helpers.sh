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

    case "${AUTH_TYPE:-service_principal}" in
        pat)
            if [ -z "${AZURE_DEVOPS_PAT:-}" ]; then
                echo "ERROR: AZURE_DEVOPS_PAT must be set when AUTH_TYPE=pat"
                exit 1
            fi
            echo "Using PAT authentication..."
            echo "$AZURE_DEVOPS_PAT" | az devops login --organization "$org_url"
            ;;
        service_principal)
            echo "Using service principal authentication..."
            ;;
        *)
            echo "ERROR: Invalid AUTH_TYPE '${AUTH_TYPE}'. Must be 'service_principal' or 'pat'."
            exit 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Shared Azure DevOps REST / data helpers
#
# These functions are intentionally defensive: they never abort the calling
# script. Detection failures degrade gracefully so that a missing optional
# permission (e.g. the Distributed Task elastic pools API) does not break the
# primary analysis.
# ---------------------------------------------------------------------------

# Build an Authorization header value for direct REST calls. Honours PAT or
# service-principal auth. Echoes nothing if no credential is available.
ado_auth_header() {
    if [ "${AUTH_TYPE:-service_principal}" = "pat" ]; then
        local pat="${AZURE_DEVOPS_EXT_PAT:-${AZURE_DEVOPS_PAT:-}}"
        [ -z "$pat" ] && return 0
        printf 'Basic %s' "$(printf ':%s' "$pat" | base64 -w0)"
    else
        local token
        token=$(az account get-access-token \
            --resource 499b84ac-1321-427f-aa17-267ca6975798 \
            --query accessToken -o tsv 2>/dev/null || echo "")
        [ -n "$token" ] && printf 'Bearer %s' "$token"
    fi
}

# Newline-separated list of elastic (VMSS / scale-set / agent-cloud) pool IDs.
# Populated by load_elastic_pool_ids; empty until then or on failure.
AZ_ELASTIC_POOL_IDS=""

# Populate AZ_ELASTIC_POOL_IDS from the Distributed Task "elasticpools" API.
# Best-effort: prefers `az devops invoke` (proxy/auth aware, matches the rest of
# the toolchain) and falls back to a direct REST call. Leaves the list empty if
# the API is unavailable or the identity lacks the agent pools read scope.
load_elastic_pool_ids() {
    local org_url="https://dev.azure.com/$AZURE_DEVOPS_ORG"
    AZ_ELASTIC_POOL_IDS=""
    local resp=""

    resp=$(az devops invoke \
        --area distributedtask --resource elasticpools \
        --org "$org_url" --api-version 7.1 \
        --output json 2>/dev/null || echo "")

    if ! echo "$resp" | jq -e '.value // .[0]' >/dev/null 2>&1; then
        local hdr; hdr=$(ado_auth_header)
        if [ -n "$hdr" ]; then
            resp=$(curl -s --max-time 20 -H "Authorization: $hdr" \
                "$org_url/_apis/distributedtask/elasticpools?api-version=7.1" 2>/dev/null || echo "")
        fi
    fi

    if echo "$resp" | jq -e '.value' >/dev/null 2>&1; then
        AZ_ELASTIC_POOL_IDS=$(echo "$resp" | jq -r '.value[].poolId // empty' 2>/dev/null)
    fi

    if [ -n "$AZ_ELASTIC_POOL_IDS" ]; then
        echo "  Detected $(echo "$AZ_ELASTIC_POOL_IDS" | grep -c . ) elastic (VMSS/scale-set) pool(s) via the elastic pools API." >&2
    fi
}

# Return 0 (true) if a pool is elastic/VMSS-backed, else 1.
# A pool is considered elastic when ANY of the following hold:
#   - its id is listed by the elastic pools API (authoritative, ADO-managed VMSS)
#   - it is backed by an agent cloud (.agentCloudId is set)
#   - it has an autoscale target size (.targetSize is set)
# Args: $1 = pool JSON object
pool_is_elastic() {
    local pool_json="$1"
    local pid agent_cloud target
    pid=$(echo "$pool_json" | jq -r '.id // empty')
    agent_cloud=$(echo "$pool_json" | jq -r '.agentCloudId // empty')
    target=$(echo "$pool_json" | jq -r '.targetSize // empty')

    if [ -n "$pid" ] && [ -n "$AZ_ELASTIC_POOL_IDS" ] && grep -qx "$pid" <<<"$AZ_ELASTIC_POOL_IDS"; then
        return 0
    fi
    [ -n "$agent_cloud" ] && [ "$agent_cloud" != "null" ] && return 0
    [ -n "$target" ] && [ "$target" != "null" ] && return 0
    return 1
}

# Classify a pool's agents with VMSS / ephemeral awareness and echo shell
# assignments suitable for `eval`. Output variables:
#   AGENT_COUNT, ONLINE_COUNT, OFFLINE_COUNT, BUSY_COUNT
#   POOL_KIND        : elastic | ephemeral | static
#   EXPECTED_OFFLINE : offline agents that are expected churn (elastic/ephemeral)
#                      and must NOT be reported as a capacity problem
#
# Rationale: elastic pools (ADO-managed VMSS) and self-managed scale-set / AKS /
# container farms continuously create and tear down agents. Torn-down instances
# linger as "offline" registrations, so a raw offline count is misleading. The
# meaningful signal for these pools is ONLINE capacity, not offline backlog.
#
# Args: $1 = agents JSON array, $2 = is_elastic ("true"/"false")
classify_pool_agents() {
    local agents="$1" is_elastic="${2:-false}"
    local ephemeral_ratio="${EPHEMERAL_OFFLINE_RATIO:-60}"

    local counts total online offline busy
    counts=$(echo "$agents" | jq -c '{
        total:   length,
        online:  ([.[] | select(.status == "online")]  | length),
        offline: ([.[] | select(.status == "offline")] | length),
        busy:    ([.[] | select(.assignedRequest != null)] | length)
    }')
    total=$(echo "$counts" | jq -r '.total')
    online=$(echo "$counts" | jq -r '.online')
    offline=$(echo "$counts" | jq -r '.offline')
    busy=$(echo "$counts" | jq -r '.busy')

    local kind="static" expected_offline=0
    if [ "$is_elastic" = "true" ]; then
        kind="elastic"
        expected_offline=$offline
    elif [ "$online" -gt 0 ] && [ "$total" -gt 0 ]; then
        local off_ratio=$(( offline * 100 / total ))
        if [ "$off_ratio" -ge "$ephemeral_ratio" ]; then
            # Online capacity exists but offline dominates: classic signature of
            # a self-managed VMSS/AKS/container pool leaving stale registrations.
            kind="ephemeral"
            expected_offline=$offline
        fi
    fi

    echo "AGENT_COUNT=$total"
    echo "ONLINE_COUNT=$online"
    echo "OFFLINE_COUNT=$offline"
    echo "BUSY_COUNT=$busy"
    echo "POOL_KIND=$kind"
    echo "EXPECTED_OFFLINE=$expected_offline"
}

# Fetch ALL user entitlements, transparently paginating past the 100-row API
# default (max page size is 10000). Echoes a JSON object:
#   {items:[...], totalCount:N, partial:bool}
# 'partial' is true when pagination stopped early (a page failed after the first,
# or the safety cap was hit), so callers can flag incomplete results.
# Returns non-zero only if the very first page cannot be retrieved.
#
# Runs in a subshell ( ... ) so the EXIT trap reliably removes the temp dir on
# any exit path (including set -e aborts), avoiding leftover users.XXXXXX dirs.
get_all_users() (
    org_url="https://dev.azure.com/$AZURE_DEVOPS_ORG"
    page_size="${USER_PAGE_SIZE:-1000}"
    # Validate/clamp page size (API maximum is 10000; 0/invalid would loop forever).
    case "$page_size" in
        ''|*[!0-9]*) page_size=1000 ;;
    esac
    [ "$page_size" -lt 1 ] && page_size=1000
    [ "$page_size" -gt 10000 ] && page_size=10000

    skip=0; idx=0; partial=false
    tmp=$(mktemp -d users.XXXXXX)
    trap 'rm -rf "$tmp"' EXIT

    while :; do
        if ! az_with_retry az devops user list \
                --org "$org_url" --top "$page_size" --skip "$skip" --output json; then
            # Tolerate a mid-pagination failure if we already have data, but
            # flag the result as partial.
            if [ "$idx" -gt 0 ]; then
                partial=true
                echo "  WARNING: user pagination stopped early after a page failure; results may be incomplete." >&2
                break
            fi
            exit 1
        fi
        # Persist each page to its own file. Merging via files (rather than
        # command-line --argjson) avoids ARG_MAX limits on large organisations.
        echo "$AZ_RESULT" | jq -c '.items // []' > "$tmp/page_${idx}.json"
        got=$(jq 'length' "$tmp/page_${idx}.json")
        idx=$((idx + 1))
        [ "$got" -lt "$page_size" ] && break
        skip=$((skip + page_size))
        if [ "$skip" -ge 100000 ]; then
            partial=true
            echo "  WARNING: user pagination hit the 100000-row safety cap; results may be incomplete." >&2
            break
        fi
    done

    jq -s 'add // []' "$tmp"/page_*.json \
        | jq --argjson partial "$partial" \
            '{items: ., totalCount: (. | length), partial: $partial}'
)

# Fetch agents for every non-hosted pool concurrently, writing one JSON file per
# pool to <out_dir>/agents_<poolId>.json. This turns what was an O(pools)
# sequential wall of `az` calls into a bounded-parallel pass, which is the
# dominant cost for organisations with hundreds of pools.
#
# On a fetch FAILURE the file is written as {"__fetch_error__": true} (and the
# stderr is preserved in agents_<poolId>.err) so callers can distinguish a
# permission/timeout/throttling error from a genuinely empty pool. Use the
# agents_fetch_failed helper below to test for this.
# Args: $1 = pools JSON array, $2 = output dir, $3 = max parallelism (default 8)
fetch_pool_agents_parallel() {
    local pools_json="$1" out_dir="$2"
    local max_par="${3:-${AGENT_FETCH_PARALLELISM:-8}}"
    local org_url="https://dev.azure.com/$AZURE_DEVOPS_ORG"
    # Validate/clamp parallelism. xargs -P 0 means UNLIMITED concurrency, which
    # would spawn one `az` per pool and overwhelm the runner/API.
    case "$max_par" in
        ''|*[!0-9]*) max_par=8 ;;
    esac
    [ "$max_par" -lt 1 ] && max_par=1
    [ "$max_par" -gt 32 ] && max_par=32
    mkdir -p "$out_dir"
    echo "$pools_json" \
        | jq -r '.[] | select((.isHosted // false) == false) | .id' \
        | xargs -r -P "$max_par" -I {} bash -c '
            out="$1/agents_$2.json"
            err="$1/agents_$2.err"
            if az pipelines agent list --pool-id "$2" --org "$3" --output json >"$out" 2>"$err"; then
                rm -f "$err"
            else
                # Preserve the error; write a marker so callers report a real
                # per-pool access/availability failure instead of "no agents".
                echo "{\"__fetch_error__\": true}" >"$out"
            fi
          ' _ "$out_dir" {} "$org_url"
}

# Return 0 if the agents file for a pool indicates a fetch failure (marker), and
# echo a short error detail (from the .err file) on stdout.
# Args: $1 = path to agents_<poolId>.json
agents_fetch_failed() {
    local f="$1"
    [ -s "$f" ] || return 1
    if jq -e 'type == "object" and (.__fetch_error__ == true)' "$f" >/dev/null 2>&1; then
        local errf="${f%.json}.err"
        [ -s "$errf" ] && head -c 300 "$errf" | tr '\n' ' '
        return 0
    fi
    return 1
}
