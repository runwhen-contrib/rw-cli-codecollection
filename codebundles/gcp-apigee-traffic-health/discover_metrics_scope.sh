#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Discover Apigee Proxies and Environments for Metrics
#
# Enumerates API proxies, environments, and target servers at org scope to
# scope the metric checks and map proxy/environment labels for the Cloud
# Monitoring queries. Uses the Apigee Admin API.
#
# REQUIRED ENV VARS:
#   APIGEE_ORG         - Apigee organization name
#   GCP_PROJECT_ID     - GCP project ID hosting the Apigee runtime
#
# OPTIONAL ENV VARS:
#   MOCK_DATA_FILE     - Path to a mock scope JSON file (for deterministic tests)
#
# OUTPUTS:
#   apigee_scope.json      - Enriched scope object (proxies, environments, targets)
#   discovery_issues.json  - JSON array of issues (usually empty on success)
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${APIGEE_ORG:?Must set APIGEE_ORG}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

SCOPE_FILE="apigee_scope.json"
ISSUES_FILE="discovery_issues.json"
issues_json='[]'

echo "Discovering Apigee scope for org: $APIGEE_ORG (project: $GCP_PROJECT_ID)"

# Use mock data if provided (deterministic test mode), else live Apigee API.
if [ -n "${MOCK_DATA_FILE:-}" ] && [ -f "$MOCK_DATA_FILE" ]; then
    echo "Using mock scope data from $MOCK_DATA_FILE"
    cp "$MOCK_DATA_FILE" "$SCOPE_FILE"
    echo "Scope written to $SCOPE_FILE from mock data."
    echo "$issues_json" > "$ISSUES_FILE"
    cat "$SCOPE_FILE"
    exit 0
fi

access_token=$(gcloud auth print-access-token 2>/dev/null || echo "")
if [ -z "$access_token" ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Cannot authenticate to Apigee for org \`$APIGEE_ORG\`" \
        --arg details "Unable to obtain an access token via gcloud for the Apigee Admin API." \
        --arg severity "4" \
        --arg expected "Apigee organization resources should be retrievable" \
        --arg actual "Could not obtain access token" \
        --arg next_steps "Ensure the service account has roles/apigee.viewer (or apigee.proxyviewer) and is properly authenticated." \
        '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"expected":$expected,"actual":$actual,"next_steps":$next_steps}]')
    echo "$issues_json" > "$ISSUES_FILE"
    echo "[]" > "$SCOPE_FILE"
    exit 0
fi

BASE="https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG"

api_get() {
    local url="$1"
    curl -s -H "Authorization: Bearer $access_token" "$url" 2>/dev/null || echo "{}"
}

# --- Proxies ---
proxies_resp=$(api_get "$BASE/apis")
if echo "$proxies_resp" | jq -e 'has("error")' >/dev/null 2>&1; then
    err=$(echo "$proxies_resp" | jq -r '.error.message // "unknown error"')
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Cannot list Apigee proxies for org \`$APIGEE_ORG\`" \
        --arg details "Apigee Admin API /apis failed: $err" \
        --arg severity "4" \
        --arg expected "API proxies should be enumerable to scope metric checks" \
        --arg actual "Listing proxies failed: $err" \
        --arg next_steps "Verify the service account has apigee.proxies.get/list permission and the Apigee API is enabled." \
        '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"expected":$expected,"actual":$actual,"next_steps":$next_steps}]')
    echo "$issues_json" > "$ISSUES_FILE"
    echo "[]" > "$SCOPE_FILE"
    echo "Proxy discovery failed. Issues written to $ISSUES_FILE"
    exit 0
fi
proxies=$(echo "$proxies_resp" | jq -r '.proxies[].name' 2>/dev/null)

# --- Environments ---
envs_resp=$(api_get "$BASE/environments")
envs=$(echo "$envs_resp" | jq -r '.[] // empty' 2>/dev/null)

# --- Target servers per environment ---
target_servers_json='[]'
if [ -n "$envs" ] && [ "$envs" != "null" ]; then
    while IFS= read -r env; do
        [ -z "$env" ] && continue
        ts_resp=$(api_get "$BASE/environments/$env/targetservers")
        ts_names=$(echo "$ts_resp" | jq -r '.targetServers[].name // empty' 2>/dev/null || true)
        while IFS= read -r ts; do
            [ -z "$ts" ] && continue
            target_servers_json=$(echo "$target_servers_json" | jq \
                --arg name "$ts" --arg env "$env" \
                '. += [{"name":$name,"environment":$env}]')
        done <<< "$ts_names"
    done <<< "$envs"
fi

# --- Assemble scope ---
pcount=$(echo "$proxies" | grep -c . || true)
ecount=$(echo "$envs" | grep -c . || true)

jq -n \
    --arg org "$APIGEE_ORG" \
    --arg project "$GCP_PROJECT_ID" \
    --argjson proxies "$(echo "$proxies" | jq -Rr 'split("\n") | map(select(length>0))' 2>/dev/null || echo '[]')" \
    --argjson environments "$(echo "$envs" | jq -Rr 'split("\n") | map(select(length>0))' 2>/dev/null || echo '[]')" \
    --argjson target_servers "$target_servers_json" \
    '{organization:$org, project:$project, proxies:$proxies, environments:$environments, target_servers:$target_servers}' > "$SCOPE_FILE"

echo "Discovered $pcount proxy(ies), $ecount environment(s), and $(echo "$target_servers_json" | jq 'length') target server(s)."
echo "Proxies: $(echo "$proxies" | tr '\n' ' ')"
echo "Environments: $(echo "$envs" | tr '\n' ' ')"

echo "$issues_json" > "$ISSUES_FILE"
echo "Scope written to $SCOPE_FILE"
cat "$SCOPE_FILE"
