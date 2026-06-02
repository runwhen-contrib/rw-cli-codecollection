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
# Azure DevOps public status page (platform incidents)
#
# The status portal embeds a NUMERIC health code in its HTML/JS payload:
#   1 = unhealthy, 2 = degraded, 3 = advisory, 4 = healthy
# (matches ScopeHealth enum order; 4 is "Everything is looking good".)
# Older scripts incorrectly assumed 1=healthy and treated 4 as an outage.
#
# Prefer the official Status REST API, which returns string health values.
# ---------------------------------------------------------------------------

# Probe whether Azure DevOps is reporting a platform-wide incident.
# Sets globals: ADO_PLATFORM_INCIDENT_OK (0|1), ADO_PLATFORM_HEALTH, ADO_PLATFORM_STATUS_MESSAGE
# Test override: SLI_INCIDENT_HEALTH may be a portal numeric code (1-4) or API string (healthy, degraded, ...).
ado_platform_incident_probe() {
    ADO_PLATFORM_INCIDENT_OK=1
    ADO_PLATFORM_HEALTH="unknown"
    ADO_PLATFORM_STATUS_MESSAGE=""

    if [ -n "${SLI_INCIDENT_HEALTH:-}" ]; then
        ADO_PLATFORM_HEALTH="${SLI_INCIDENT_HEALTH}"
        case "$(printf '%s' "${SLI_INCIDENT_HEALTH}" | tr '[:upper:]' '[:lower:]')" in
            healthy|advisory|4|3) ADO_PLATFORM_INCIDENT_OK=1 ;;
            degraded|unhealthy|2|1) ADO_PLATFORM_INCIDENT_OK=0 ;;
            *) ADO_PLATFORM_INCIDENT_OK=1 ;;
        esac
        return 0
    fi

    local api_json overall msg bad_geo
    api_json=$(curl -s --max-time 15 \
        'https://status.dev.azure.com/_apis/status/health?api-version=7.1-preview.1' 2>/dev/null || true)
    overall=$(printf '%s' "$api_json" | jq -r '.status.health // empty' 2>/dev/null)
    msg=$(printf '%s' "$api_json" | jq -r '.status.message // empty' 2>/dev/null)
    if [ -n "$overall" ]; then
        ADO_PLATFORM_HEALTH="$overall"
        ADO_PLATFORM_STATUS_MESSAGE="$msg"
        case "$(printf '%s' "$overall" | tr '[:upper:]' '[:lower:]')" in
            unhealthy|degraded) ADO_PLATFORM_INCIDENT_OK=0 ;;
            *) ADO_PLATFORM_INCIDENT_OK=1 ;;
        esac
        bad_geo=$(printf '%s' "$api_json" | jq -r '
            ([.services[]?.geographies[]?.health // empty | ascii_downcase]
             | any(. == "degraded" or . == "unhealthy")) // false
        ' 2>/dev/null || echo false)
        if [ "$bad_geo" = "true" ]; then
            ADO_PLATFORM_INCIDENT_OK=0
        fi
        return 0
    fi

    # HTML/JS fallback (numeric portal enum). Use a private temp file so callers
    # are not affected if they download the status page for connectivity checks.
    local incident_num="" html_file=""
    html_file=$(mktemp ado_status_page.XXXXXX)
    if curl -s --max-time 15 -o "$html_file" 'https://status.dev.azure.com' 2>/dev/null; then
        local svc
        svc=$(grep -o '"serviceStatus":{[^}]*"health":[0-9]*[^}]*}' "$html_file" 2>/dev/null | head -1 || true)
        incident_num=$(printf '%s' "$svc" | grep -o '"health":[0-9]*' | head -1 | cut -d':' -f2)
        ADO_PLATFORM_STATUS_MESSAGE=$(printf '%s' "$svc" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
    fi
    rm -f "$html_file"

    if [ -n "$incident_num" ]; then
        ADO_PLATFORM_HEALTH="$incident_num"
        case "$incident_num" in
            1|2) ADO_PLATFORM_INCIDENT_OK=0 ;;   # unhealthy, degraded
            3|4) ADO_PLATFORM_INCIDENT_OK=1 ;;   # advisory, healthy
            *) ADO_PLATFORM_INCIDENT_OK=1 ;;
        esac
    fi
}

# List organization-scoped security groups (Graph). The az CLI defaults to
# --scope project, which fails with "project must be specified" unless a default
# project is configured. Org-health tasks must use --scope organization.
ado_security_groups_json() {
    local org_url="https://dev.azure.com/${AZURE_DEVOPS_ORG}"
    az devops security group list --org "$org_url" --scope organization --output json 2>/dev/null || echo ""
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

# Best-effort resolution of the authenticated identity. Echoes a JSON object:
#   {name, id, email, auth_type, confirmed}
# Tries `az devops invoke` FIRST so it shares the exact auth + proxy path as the
# tasks/probes (a raw curl often fails behind a corporate proxy even when `az`
# succeeds, which is why PAT runs previously reported identity "unknown"). Falls
# back to a direct connectionData REST call. Never fails the caller.
ado_identity_json() {
    local org_url="https://dev.azure.com/$AZURE_DEVOPS_ORG"
    local auth="${AUTH_TYPE:-service_principal}"
    local resp=""

    resp=$(az devops invoke --area Location --resource ConnectionData \
        --org "$org_url" --api-version 7.1 --output json 2>/dev/null || echo "")

    if ! echo "$resp" | jq -e '(.authenticatedUser.id // .authorizedUser.id)' >/dev/null 2>&1; then
        local hdr; hdr=$(ado_auth_header)
        if [ -n "$hdr" ]; then
            resp=$(curl -s --max-time 15 -H "Authorization: $hdr" \
                "$org_url/_apis/connectionData?api-version=7.1" 2>/dev/null || echo "")
        fi
    fi

    # Always emit a single, valid JSON object. Callers (notably preflight) feed
    # this straight into `jq --argjson`, which aborts the whole script if it ever
    # receives an empty string — so guard every path and fall back to a valid
    # "unconfirmed" object rather than echoing nothing.
    local out=""
    if echo "$resp" | jq -e '(.authenticatedUser.id // .authorizedUser.id)' >/dev/null 2>&1; then
        out=$(echo "$resp" | jq --arg a "$auth" '
            (.authenticatedUser // .authorizedUser) as $u
            | ($u.properties.Account."$value" // $u.emailAddress // "") as $email
            | {
                name:      ($u.providerDisplayName // $u.customDisplayName // $email // "unknown"),
                id:        ($u.id // "unknown"),
                email:     $email,
                auth_type: $a,
                confirmed: true
              }' 2>/dev/null)
    fi
    if [ -z "$out" ] || ! echo "$out" | jq -e . >/dev/null 2>&1; then
        out=$(jq -n --arg a "$auth" '{name:"unknown", id:"unknown", email:"", auth_type:$a, confirmed:false}')
    fi
    echo "$out"
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
# True when a majority of agent names look auto-generated (VMSS/K8s/container).
# Args: $1 = agents JSON array
agents_look_generated() {
    echo "$1" | jq -e '
        ([.[] | .name // ""]) as $n
        | ($n | length) as $tot
        | if $tot == 0 then false
          else
            ([ $n[] | select(
                test("^azp-"; "i")
                or test("agents?-[0-9]+$"; "i")
                or test("-[0-9]+$")
            )] | length) as $gen
            | ($gen * 2) >= $tot
          end' >/dev/null 2>&1
}

# Heuristic: self-managed ephemeral farm (Kubernetes/KEDA/AKS/VMSS/container).
# Requires generated-looking agent names so static pools named "*-agent" or
# containing "elastic" are not misclassified when every agent is offline.
# Args: $1 = agents JSON array, $2 = pool name
pool_looks_ephemeral() {
    local agents="$1" pool_name="${2:-}"
    agents_look_generated "$agents" || return 1
    # Strong infra signals in the pool name reinforce the agent-name signal.
    if printf '%s' "$pool_name" \
        | grep -Eiq 'k8s|aks|kube|keda|vmss|scale.?set|ephemeral'; then
        return 0
    fi
    # Agent-name majority alone is sufficient (e.g. cts-pool + azp-maven-agent-N).
    return 0
}

# Echo up to N (default 3) agent names that match the generated/ephemeral name
# patterns, comma-separated. Used as human-readable evidence in issue details.
# Args: $1 = agents JSON array, $2 = max names (optional, default 3)
agents_generated_sample() {
    echo "$1" | jq -r --argjson n "${2:-3}" '
        [ .[] | (.name // "")
          | select(test("^azp-"; "i") or test("agents?-[0-9]+$"; "i") or test("-[0-9]+$")) ]
        | .[:$n] | join(", ")' 2>/dev/null || true
}

# Classify a pool and emit eval-able assignments. In addition to the counts and
# POOL_KIND it now exposes WHY the classification was chosen so callers can put
# concrete, plain-language evidence in the issue text:
#   POOL_KIND_REASON   : sentence describing which heuristic fired (eval-safe)
#   POOL_KIND_EVIDENCE : the specific markers (ratios, sample names) (eval-safe)
# Args: $1 = agents JSON array, $2 = is_elastic ("true"/"false"), $3 = pool name (optional)
classify_pool_agents() {
    local agents="$1" is_elastic="${2:-false}" pool_name="${3:-}"
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

    # A few generated-looking agent names to show the reader WHY a pool reads as
    # dynamic (e.g. azp-maven-agent-7). Empty string when none match.
    local gen_sample name_markers
    gen_sample=$(agents_generated_sample "$agents" 3)
    name_markers=$(printf '%s' "$pool_name" \
        | grep -Eio 'k8s|aks|kube|keda|vmss|scale.?set|ephemeral' | head -1 || true)

    local kind="static" expected_offline=0 reason="" evidence=""
    if [ "$is_elastic" = "true" ]; then
        kind="elastic"
        expected_offline=$offline
        reason="the pool is reported by the Distributed Task elastic-pools API or carries an agentCloudId/targetSize, i.e. an Azure DevOps-managed VMSS / agent-cloud (dynamic) pool"
        evidence="elastic-pools API entry or agentCloudId/targetSize marker present"
    elif [ "$online" -gt 0 ] && [ "$total" -gt 0 ] \
            && [ "$(( offline * 100 / total ))" -ge "$ephemeral_ratio" ]; then
        # Online capacity exists but offline dominates: classic signature of a
        # self-managed VMSS/AKS/container pool leaving stale registrations.
        kind="ephemeral"
        expected_offline=$offline
        reason="online capacity exists but offline registrations dominate the pool (>= ${ephemeral_ratio}% of total) -- the classic signature of a self-managed VMSS/AKS/container farm that leaves stale registrations behind as it scales"
        evidence="offline ratio $(( offline * 100 / total ))% >= ${ephemeral_ratio}% threshold${gen_sample:+; generated agent names: ${gen_sample}}"
    elif [ "$total" -gt 0 ] && [ "$offline" -eq "$total" ] \
            && pool_looks_ephemeral "$agents" "$pool_name"; then
        # Scaled-to-zero ephemeral farm: every agent offline AND the pool/agent
        # naming matches a Kubernetes/VMSS/container pattern. This is the case the
        # ratio test cannot catch (no online agents to take a ratio of), and is
        # exactly the "very high offline count" false positive to suppress.
        kind="ephemeral"
        expected_offline=$offline
        reason="every registered agent is offline AND the pool/agent naming matches a Kubernetes/VMSS/container/KEDA pattern -- a dynamic farm that has scaled to zero"
        evidence="all ${total} agents offline; generated agent names: ${gen_sample:-n/a}${name_markers:+; pool-name marker: ${name_markers}}"
    else
        reason="no dynamic markers were found (no elastic-pools API entry, no agentCloudId, no targetSize) and the agent names are not predominantly auto-generated -- treated as a persistent/static pool"
        evidence="no VMSS/scale-set/agent-cloud markers detected${gen_sample:+; generated-looking names present but below threshold: ${gen_sample}}"
    fi

    echo "AGENT_COUNT=$total"
    echo "ONLINE_COUNT=$online"
    echo "OFFLINE_COUNT=$offline"
    echo "BUSY_COUNT=$busy"
    echo "POOL_KIND=$kind"
    echo "EXPECTED_OFFLINE=$expected_offline"
    # %q keeps the free-text reason/evidence safe for `eval` in the callers.
    printf 'POOL_KIND_REASON=%q\n' "$reason"
    printf 'POOL_KIND_EVIDENCE=%q\n' "$evidence"
}

# ---------------------------------------------------------------------------
# Queued-work pressure: the ONLY signal that distinguishes an idle dynamic pool
# (scaled to zero on purpose, expected, sev 4 at most) from a real outage
# (pipelines are queued but nothing can pick them up). busy_assigned does NOT
# capture this -- a job waiting in the pool queue while online=0 has no agent to
# be "assigned" to. These helpers are best-effort and degrade to zeros so they
# can never break or fail the calling task.
# ---------------------------------------------------------------------------

# Echo the pool's job requests as a JSON array (the .value of the jobrequests
# API) or "[]" on any failure. Prefers `az devops invoke` (proxy/auth aware)
# then falls back to a direct REST call, mirroring the rest of the toolchain.
# Args: $1 = pool id
ado_pool_job_requests_json() {
    local pool_id="$1"
    local org_url="https://dev.azure.com/$AZURE_DEVOPS_ORG"
    local resp=""

    resp=$(az devops invoke \
        --area distributedtask --resource jobrequests \
        --route-parameters poolId="$pool_id" \
        --org "$org_url" --api-version 7.1 --output json 2>/dev/null || echo "")

    if ! echo "$resp" | jq -e '.value' >/dev/null 2>&1; then
        local hdr; hdr=$(ado_auth_header)
        if [ -n "$hdr" ]; then
            resp=$(curl -s --max-time 20 -H "Authorization: $hdr" \
                "$org_url/_apis/distributedtask/pools/$pool_id/jobrequests?api-version=7.1" \
                2>/dev/null || echo "")
        fi
    fi

    if echo "$resp" | jq -e '.value' >/dev/null 2>&1; then
        echo "$resp" | jq -c '.value'
    else
        echo "[]"
    fi
}

# Given job-requests JSON and an aging threshold (minutes) emit eval-able vars:
#   QUEUED_TOTAL      : requests queued but not yet picked up by any agent
#   QUEUED_AGING      : of those, how many have waited longer than the threshold
#   OLDEST_QUEUED_MIN : age (minutes, floored) of the oldest queued request
# A queued-but-unassigned request has a queueTime but no assignTime/receiveTime
# and no result/finishTime yet. All date parsing is wrapped in try/catch so a
# malformed timestamp degrades to 0 rather than aborting.
# Args: $1 = job requests JSON array, $2 = aging threshold minutes (optional)
pool_queue_pressure() {
    local jobs="$1" threshold_min="${2:-${QUEUE_AGING_THRESHOLD_MIN:-15}}"
    echo "$jobs" | jq -r --argjson thr "$threshold_min" '
        def age_min($t):
            ($t | sub("\\.[0-9]+"; "") | sub("([+-][0-9]{2}:?[0-9]{2})$"; "Z")) as $clean
            | ((try ($clean | fromdateiso8601) catch null)) as $epoch
            | if $epoch == null then 0 else ((now - $epoch) / 60) end;
        [ .[]
          | select((.result == null) and (.finishTime == null))
          | select((.reservedAgent == null) and (.assignTime == null) and (.receiveTime == null))
          | (if (.queueTime // null) != null then age_min(.queueTime) else 0 end)
        ] as $ages
        | "QUEUED_TOTAL=\($ages | length)",
          "QUEUED_AGING=\([ $ages[] | select(. >= $thr) ] | length)",
          "OLDEST_QUEUED_MIN=\((($ages | max) // 0) | floor)"
    ' 2>/dev/null || printf 'QUEUED_TOTAL=0\nQUEUED_AGING=0\nOLDEST_QUEUED_MIN=0\n'
}

# Build the one-line "is work blocked?" status used in issue details. Combines
# the queue-pressure counts with busy_assigned so the reader sees whether any
# pipeline work is actually stuck behind a pool with no online agents.
# Args: $1 = busy_assigned, $2 = QUEUED_TOTAL, $3 = QUEUED_AGING, $4 = OLDEST_QUEUED_MIN
pool_queue_status_line() {
    local busy="${1:-0}" qtotal="${2:-0}" qaging="${3:-0}" oldest="${4:-0}"
    if [ "$qaging" -gt 0 ]; then
        printf 'YES -- %s queued job(s) have been waiting >%s min (oldest %s min) with no online agent to run them. This is a real capacity outage.' \
            "$qaging" "${QUEUE_AGING_THRESHOLD_MIN:-15}" "$oldest"
    elif [ "$qtotal" -gt 0 ]; then
        printf 'PARTIAL -- %s job(s) are queued but still young (<%s min). The pool may simply be scaling up; re-check shortly.' \
            "$qtotal" "${QUEUE_AGING_THRESHOLD_MIN:-15}"
    elif [ "$busy" -gt 0 ]; then
        printf 'MAYBE -- no jobs are queued, but %s registered agent(s) still carry an assignedRequest while offline; this is usually a stale record from scale-down.' \
            "$busy"
    else
        printf 'NO -- no jobs are queued for this pool and no agent carries an assignedRequest, so nothing is currently blocked. A dynamic pool at 0 online while idle is expected.'
    fi
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

# Load agents JSON from a per-pool cache file. Returns 1 on fetch_error marker.
# Always echoes a JSON array (never a non-array body that would break jq).
# Args: $1 = path to agents_<poolId>.json
load_pool_agents_json() {
    local f="$1"
    if agents_fetch_failed "$f"; then
        return 1
    fi
    if [ ! -s "$f" ]; then
        echo "[]"
        return 0
    fi
    if jq -e 'type == "array"' "$f" >/dev/null 2>&1; then
        cat "$f"
    else
        echo "[]"
    fi
}

# Rich issue_details text for agent-pool findings (RunWhen agents consume the
# JSON "details" field as issue_details). The text explains, in plain language,
# WHY agents are offline and whether any pipeline work is actually blocked, so a
# reader does not mistake expected dynamic scale-down for an outage.
# Args: summary, pool_name, pool_id, pool_type, pool_kind, total, online, offline,
#       busy, expected_offline,
#       [extra paragraph], [sample offline agent names],
#       [classification reason (POOL_KIND_REASON)], [work-blocked status line]
ado_pool_issue_details() {
    local summary="$1" pool_name="$2" pool_id="$3" pool_type="$4" pool_kind="$5"
    local total="$6" online="$7" offline="$8" busy="$9" expected_offline="${10:-0}"
    local extra="${11:-}" sample="${12:-}" classification="${13:-}" queue_status="${14:-}"
    local org="${AZURE_DEVOPS_ORG:-unknown}"

    printf '%s\n\n' "$summary"
    printf 'Organization: %s\n' "$org"
    printf 'Pool: %s (id=%s, poolType=%s, classified_as=%s)\n' "$pool_name" "$pool_id" "$pool_type" "$pool_kind"
    printf 'Agent counts: total=%s online=%s offline=%s busy_assigned=%s expected_offline_churn=%s\n' \
        "$total" "$online" "$offline" "$busy" "$expected_offline"
    [ -n "$classification" ] && printf 'Why classified as "%s": %s\n' "$pool_kind" "$classification"

    # Plain-language likely cause, tailored to the pool kind. This is the core
    # of the "explain the WHY" requirement: dynamic vs static get very different
    # explanations because the offline count means very different things.
    printf '\nLikely cause:\n'
    case "$pool_kind" in
        elastic|ephemeral)
            printf -- '- This pool provides DYNAMIC capacity (VMSS / scale-set / Kubernetes / container / agent-cloud). Agents are created on demand and torn down when idle.\n'
            printf -- '- The offline registrations are EXPECTED scale-down artifacts of autoscale, not failed machines. A dynamic pool sitting at 0 online while idle is normal and is NOT an outage.\n'
            if [ "${busy:-0}" -gt 0 ]; then
                printf -- '- Note: %s registered agent(s) still carry an assignedRequest while not online. That is usually a stale record left by scale-down; confirm the scaler is replacing them.\n' "$busy"
            fi
            ;;
        static)
            printf -- '- This is a STATIC pool (persistent, manually-managed agents). Offline agents here are NOT expected churn -- each one is lost capacity.\n'
            printf -- '- A static agent goes offline when its agent service is stopped, the host is powered off or unreachable, it lost network connectivity to dev.azure.com, or the credentials/PAT it runs under expired.\n'
            ;;
        *)
            printf -- '- Pool kind could not be determined (agent data may be unreadable). Treat the counts above with caution until agents can be listed.\n'
            ;;
    esac

    # Whether pipeline work is actually blocked. Driven by the queue-pressure
    # check when available; otherwise spells out the busy_assigned caveat.
    printf '\nIs pipeline work actually blocked?\n'
    if [ -n "$queue_status" ]; then
        printf -- '- %s\n' "$queue_status"
    else
        printf -- '- busy_assigned counts agents with a non-null assignedRequest. It does NOT count pipeline jobs waiting in the pool queue while online=0. If online=0 AND builds are queued, work is blocked regardless of busy_assigned.\n'
    fi

    printf '\nReading the counts:\n'
    printf -- '- expected_offline_churn=%s of the %s offline registrations are attributed to dynamic scale-down (0 for static pools).\n' "$expected_offline" "$offline"
    printf -- '- For dynamic pools the actionable signal is ONLINE capacity + queued work, NOT the offline backlog.\n'

    printf '\nNext step:\n'
    case "$pool_kind" in
        elastic|ephemeral)
            printf -- '- Open Organization Settings > Agent pools > %s and confirm autoscale/VMSS/KEDA sizing and the backing service connection are healthy. No action is needed if no pipelines are waiting.\n' "$pool_name"
            ;;
        static)
            printf -- '- Open Organization Settings > Agent pools > %s, then on each offline agent: restart the agent service, confirm the host is powered on and can reach dev.azure.com, and verify the agent credentials/PAT.\n' "$pool_name"
            ;;
        *)
            printf -- '- Open Organization Settings > Agent pools > %s to inspect the pool once agent data can be retrieved.\n' "$pool_name"
            ;;
    esac

    [ -n "$extra" ] && printf '\n%s\n' "$extra"
    if [ -n "$sample" ]; then
        case "$pool_kind" in
            elastic|ephemeral)
                printf '\nSample offline agents (note the generated/ephemeral naming): %s\n' "$sample" ;;
            *)
                printf '\nSample offline agents: %s\n' "$sample" ;;
        esac
    fi
    printf '\nAPI probed: GET .../distributedtask/pools/%s/agents?includeAssignedRequest=true\n' "$pool_id"
}

# Generic structured issue_details for non-pool scripts.
# Args: summary line, then zero or more "Key: value" lines
ado_issue_details() {
    local summary="$1"; shift
    printf '%s\n\n--- Context ---\n' "$summary"
    printf 'Organization: %s\n' "${AZURE_DEVOPS_ORG:-unknown}"
    for line in "$@"; do
        [ -n "$line" ] && printf '%s\n' "$line"
    done
}

# Fetch agents for every non-hosted pool concurrently, writing one JSON file per
# pool to <out_dir>/agents_<poolId>.json. This turns what was an O(pools)
# sequential wall of calls into a bounded-parallel pass, the dominant cost for
# organisations with hundreds of pools.
#
# Agents are fetched via a direct REST call (curl) rather than `az pipelines
# agent list`. The az CLI pays a ~1s Python startup PER pool, so for ~200 pools
# that alone is several minutes and was causing the 180s task timeouts. The PAT/
# bearer header is resolved once and passed to the workers via the environment
# (not argv) so it never appears in `ps`. When no credential is available we
# fall back to the az CLI.
#
# On a fetch FAILURE the file is written as {"__fetch_error__": true} (and the
# error is preserved in agents_<poolId>.err) so callers can distinguish a
# permission/timeout/throttling error from a genuinely empty pool. Use the
# agents_fetch_failed helper below to test for this.
# Args: $1 = pools JSON array, $2 = output dir, $3 = max parallelism (default 20)
fetch_pool_agents_parallel() {
    local pools_json="$1" out_dir="$2"
    local max_par="${3:-${AGENT_FETCH_PARALLELISM:-20}}"
    local org_url="https://dev.azure.com/$AZURE_DEVOPS_ORG"
    # Validate/clamp parallelism. xargs -P 0 means UNLIMITED concurrency, which
    # would spawn one worker per pool and overwhelm the runner/API.
    case "$max_par" in
        ''|*[!0-9]*) max_par=20 ;;
    esac
    [ "$max_par" -lt 1 ] && max_par=1
    [ "$max_par" -gt 32 ] && max_par=32
    mkdir -p "$out_dir"

    # Resolve auth once; pass via env to the parallel workers (keeps PAT out of argv).
    export ADO_AUTH_HDR; ADO_AUTH_HDR=$(ado_auth_header)

    echo "$pools_json" \
        | jq -r '.[] | select((.isHosted // false) == false) | .id' \
        | xargs -r -P "$max_par" -I {} bash -c '
            pool="$2"; out="$1/agents_$2.json"; err="$1/agents_$2.err"; raw="$1/agents_$2.raw"
            org="$3"
            mark_err() { echo "{\"__fetch_error__\": true}" >"$out"; }
            az_fetch() {
                az pipelines agent list --pool-id "$pool" --org "$org" \
                    --include-assigned-request --output json >"$out" 2>"$err"
            }
            wrote=false
            if [ -n "${ADO_AUTH_HDR:-}" ]; then
                url="$org/_apis/distributedtask/pools/$pool/agents?includeAssignedRequest=true&api-version=7.1"
                if curl -fsS --max-time 60 -H "Authorization: $ADO_AUTH_HDR" "$url" -o "$raw" 2>"$err"; then
                    if jq -e "type == \"object\" and (.value | type) == \"array\"" "$raw" >/dev/null 2>&1 \
                            && jq -c ".value" "$raw" >"$out" 2>/dev/null && [ -s "$out" ]; then
                        rm -f "$raw" "$err"; wrote=true
                    fi
                fi
                rm -f "$raw"
            fi
            if [ "$wrote" = false ]; then
                if az_fetch; then
                    rm -f "$err"
                else
                    mark_err
                fi
            fi
          ' _ "$out_dir" {} "$org_url"
    unset ADO_AUTH_HDR
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

# ===========================================================================
# Phase 0 single-pass build-dataset helpers
#
# WHY: the per-task pipeline scripts previously iterated over EVERY pipeline in
# a project, issuing `az pipelines runs list --pipeline-id <id>` once per
# pipeline (plus follow-up calls). On large projects (hundreds of pipelines)
# that serial wall of ~6s/call calls blew past the 180s/300s Robot task
# timeouts. These helpers fetch the project's builds ONCE via a small number of
# paginated Build REST calls into a single on-disk dataset; every task then
# derives its signals (failures, queue aging, long-running, perf percentiles)
# from that dataset with jq -- with NO further per-pipeline calls.
# ===========================================================================

# Convert a lookback window like "24h", "30d", "90m", "2w" to an ISO-8601 UTC
# timestamp at (now - window), suitable for the Build API minTime parameter.
# Unrecognised input falls back to 24h.
window_to_min_time() {
    local window="${1:-24h}" num unit spec
    num=$(printf '%s' "$window" | sed -E 's/[^0-9].*$//')
    unit=$(printf '%s' "$window" | sed -E 's/^[0-9]*//' | tr '[:upper:]' '[:lower:]')
    [ -z "$num" ] && { num=24; unit=h; }
    case "$unit" in
        m|min|mins|minute|minutes) spec="$num minutes ago" ;;
        h|hr|hrs|hour|hours|"")    spec="$num hours ago" ;;
        d|day|days)                spec="$num days ago" ;;
        w|wk|wks|week|weeks)       spec="$((num * 7)) days ago" ;;
        *)                         spec="24 hours ago" ;;
    esac
    date -u -d "$spec" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# URL-encode a string (project names may contain spaces, e.g. "IT Services").
ado_urlencode() { jq -rn --arg s "${1:-}" '$s|@uri' 2>/dev/null || printf '%s' "${1:-}"; }

# Fetch a project's builds into a single JSON-array file ($2). The dataset is the
# UNION of:
#   A) builds that FINISHED within the lookback window (for failures, completed
#      long-running, and performance percentiles), and
#   B) builds currently ACTIVE (inProgress / notStarted) -- a point-in-time set
#      with NO historical filter (for queue aging and in-flight long-running),
# de-duplicated by build id. Echoes the resulting build count on stdout.
#
# An on-disk cache keyed by org|project|window means that when several tasks in
# the same suite need the same dataset, only the FIRST call hits the API; the
# rest reuse the cached file (set BUILDS_CACHE_ENABLED=false to disable;
# BUILDS_CACHE_TTL_SEC, default 600, bounds staleness across runs).
#
# Build fields used downstream: id, buildNumber, status, result, queueTime,
# startTime, finishTime, sourceBranch, sourceVersion, reason, definition.{id,name},
# _links.web.href. These mirror what `az pipelines runs list` returned, so the
# derivations are drop-in.
#
# Args: $1 = project name, $2 = output file, $3 = lookback window
#       (default $RW_LOOKBACK_WINDOW or 24h).
# Returns: 0 on success (even with partial pages), non-zero only if NO data could
#          be fetched and no cache exists.
fetch_project_builds() {
    local project="$1" out_file="$2"
    local window="${3:-${RW_LOOKBACK_WINDOW:-24h}}"
    local org_url="https://dev.azure.com/$AZURE_DEVOPS_ORG"
    local page_size="${BUILDS_PAGE_SIZE:-1000}"
    local max_pages="${BUILDS_MAX_PAGES:-25}"
    local min_time proj_enc
    min_time=$(window_to_min_time "$window")
    proj_enc=$(ado_urlencode "$project")

    # ---- cache lookup -----------------------------------------------------
    local cache_dir cache_key cache_file ttl now mtime age
    cache_dir="${BUILDS_CACHE_DIR:-.ado_cache}"
    mkdir -p "$cache_dir" 2>/dev/null || cache_dir="."
    cache_key=$(printf '%s|%s|%s' "$AZURE_DEVOPS_ORG" "$project" "$window" \
        | { md5sum 2>/dev/null || cksum; } | awk '{print $1}')
    cache_file="$cache_dir/ado_builds_${cache_key}.json"
    ttl="${BUILDS_CACHE_TTL_SEC:-600}"
    if [ "${BUILDS_CACHE_ENABLED:-true}" = "true" ] && [ -s "$cache_file" ]; then
        now=$(date +%s); mtime=$(date -r "$cache_file" +%s 2>/dev/null || echo 0)
        age=$((now - mtime))
        if [ "$mtime" -gt 0 ] && [ "$age" -lt "$ttl" ]; then
            { cp "$cache_file" "$out_file" 2>/dev/null || cat "$cache_file" > "$out_file"; }
            echo "  Reusing cached build dataset ($cache_file, age ${age}s, window ${window})." >&2
            jq 'length' "$out_file" 2>/dev/null || echo 0
            return 0
        fi
    fi

    local hdr work rc=0
    hdr=$(ado_auth_header)
    work=$(mktemp -d ado_builds.XXXXXX)

    # Run one paginated query variant, appending each page's .value array to a
    # file in $work. Uses dynamic scoping to read $hdr/$work/$proj_enc/etc.
    _fetch_builds_query() {
        local extra="$1" tag="$2" page=0 cont="" url body hdrs
        while [ "$page" -lt "$max_pages" ]; do
            url="$org_url/$proj_enc/_apis/build/builds?api-version=7.1&\$top=$page_size$extra"
            [ -n "$cont" ] && url="$url&continuationToken=$cont"
            if [ -n "$hdr" ]; then
                hdrs="$work/h_${tag}_${page}.txt"
                if ! body=$(curl -fsS --max-time 60 -D "$hdrs" -H "Authorization: $hdr" "$url" 2>/dev/null); then
                    return 1
                fi
                printf '%s' "$body" | jq -c '.value // []' > "$work/p_${tag}_${page}.json" 2>/dev/null || true
                cont=$(grep -i '^x-ms-continuationtoken:' "$hdrs" 2>/dev/null \
                    | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '\r')
            else
                # No usable credential: fall back to az devops invoke (single page,
                # no continuation token support).
                body=$(az devops invoke --area build --resource builds \
                    --route-parameters project="$project" --org "$org_url" \
                    --api-version 7.1 --output json 2>/dev/null || echo "")
                printf '%s' "$body" | jq -c '.value // []' > "$work/p_${tag}_${page}.json" 2>/dev/null || true
                cont=""
            fi
            page=$((page + 1))
            [ -z "$cont" ] && break
        done
        return 0
    }

    # A) finished builds in the lookback window
    _fetch_builds_query "&minTime=$min_time&queryOrder=finishTimeDescending" "fin" || rc=1
    # B) currently active builds (point-in-time; no historical filter)
    _fetch_builds_query "&statusFilter=inProgress,notStarted&queryOrder=queueTimeDescending" "act" || true

    if ls "$work"/p_*.json >/dev/null 2>&1; then
        jq -s 'add // [] | unique_by(.id)' "$work"/p_*.json > "$out_file" 2>/dev/null || echo '[]' > "$out_file"
    else
        echo '[]' > "$out_file"
    fi
    rm -rf "$work"
    unset -f _fetch_builds_query

    if [ "${BUILDS_CACHE_ENABLED:-true}" = "true" ] && [ -s "$out_file" ] \
            && jq -e 'type == "array"' "$out_file" >/dev/null 2>&1; then
        cp "$out_file" "$cache_file" 2>/dev/null || true
    fi

    jq 'length' "$out_file" 2>/dev/null || echo 0
    return $rc
}

# ===========================================================================
# Parallel per-pool job-request (queue) probe
#
# WHY: agent-pool-capacity.sh / platform-issue-investigation.sh already fetch
# pool AGENTS in parallel, but still probed each scaled-to-zero dynamic pool's
# job queue SERIALLY inside the loop. For orgs with hundreds of pools that idle
# at 0 online (e.g. 473 pools, many ephemeral), that serial probe was the
# dominant remaining wall. Pre-fetching all candidate pools' job requests in a
# bounded-parallel pass (identical to the agent fetch) removes that wall WITHOUT
# changing any severity logic -- callers still derive queue pressure per pool,
# just from a pre-fetched file instead of an inline serial call.
# ===========================================================================

# Fetch the job-request queue for the given pool ids concurrently, writing one
# JSON array file per pool to <out_dir>/jobreqs_<poolId>.json ("[]" on failure).
# Args: $1 = newline-separated pool ids, $2 = output dir, $3 = parallelism (default 20)
fetch_pool_job_requests_parallel() {
    local pool_ids="$1" out_dir="$2"
    local max_par="${3:-${AGENT_FETCH_PARALLELISM:-20}}"
    local org_url="https://dev.azure.com/$AZURE_DEVOPS_ORG"
    case "$max_par" in ''|*[!0-9]*) max_par=20 ;; esac
    [ "$max_par" -lt 1 ] && max_par=1
    [ "$max_par" -gt 32 ] && max_par=32
    mkdir -p "$out_dir"

    export ADO_AUTH_HDR; ADO_AUTH_HDR=$(ado_auth_header)
    printf '%s\n' "$pool_ids" | grep -E '^[0-9]+$' \
        | xargs -r -P "$max_par" -I {} bash -c '
            pool="$2"; out="$1/jobreqs_$2.json"; org="$3"; raw="$1/jr_$2.raw"
            url="$org/_apis/distributedtask/pools/$pool/jobrequests?api-version=7.1"
            if [ -n "${ADO_AUTH_HDR:-}" ] \
                 && curl -fsS --max-time 30 -H "Authorization: $ADO_AUTH_HDR" "$url" -o "$raw" 2>/dev/null \
                 && jq -e "(.value | type) == \"array\"" "$raw" >/dev/null 2>&1; then
                jq -c ".value" "$raw" > "$out" 2>/dev/null || echo "[]" > "$out"
            else
                # Fall back to az devops invoke (proxy/auth aware) for this pool.
                if resp=$(az devops invoke --area distributedtask --resource jobrequests \
                        --route-parameters poolId="$pool" --org "$org" --api-version 7.1 \
                        --output json 2>/dev/null) && printf "%s" "$resp" | jq -e ".value" >/dev/null 2>&1; then
                    printf "%s" "$resp" | jq -c ".value" > "$out" 2>/dev/null || echo "[]" > "$out"
                else
                    echo "[]" > "$out"
                fi
            fi
            rm -f "$raw"
          ' _ "$out_dir" {} "$org_url"
    unset ADO_AUTH_HDR
}

# Echo the cached job-requests array for a pool, or "[]" if absent/invalid.
# Args: $1 = path to jobreqs_<poolId>.json
load_pool_job_requests_json() {
    local f="$1"
    if [ -s "$f" ] && jq -e 'type == "array"' "$f" >/dev/null 2>&1; then
        cat "$f"
    else
        echo "[]"
    fi
}
