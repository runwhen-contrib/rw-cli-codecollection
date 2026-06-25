#!/usr/bin/env bash
# Review tenant user/group policies, export permissions, and quota policies.
set -euo pipefail
set -x

: "${VAST_VMS_ENDPOINT:?Must set VAST_VMS_ENDPOINT}"
: "${VAST_CLUSTER_NAME:?Must set VAST_CLUSTER_NAME}"
: "${VAST_TENANT_NAME:?Must set VAST_TENANT_NAME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vast-vms-helpers.sh
source "${SCRIPT_DIR}/vast-vms-helpers.sh"

vast_require_cmd curl
vast_require_cmd jq
vast_require_cmd python3

OUTPUT_FILE="tenant_config_issues.json"
issues_json='[]'

if ! vast_auth_configured; then
  issues_json="$(vast_add_api_error_issue "$issues_json" \
    "Cannot authenticate to VMS for tenant \`${VAST_TENANT_NAME}\`" \
    "vast_vms_credentials secret missing USERNAME/PASSWORD or API_TOKEN." \
    4)"
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

tenants_resp="$(vast_fetch_json_api "/tenants/")"
tenants_code="$(vast_fetch_http_code "$tenants_resp")"
tenants_body="$(vast_fetch_body "$tenants_resp")"

if [[ "$tenants_code" != "200" ]]; then
  issues_json="$(vast_add_api_error_issue "$issues_json" \
    "Tenant configuration API error for \`${VAST_TENANT_NAME}\`" \
    "HTTP ${tenants_code} from /api/tenants/. Body (truncated): ${tenants_body:0:400}" \
    4)"
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

tenant_json="$(printf '%s' "$tenants_body" | vast_find_tenant_json "$tenants_body")"
tenant_name="$(printf '%s' "$tenant_json" | jq -r '.name // .tenant_name // empty')"
if [[ -z "$tenant_name" ]]; then
  issues_json="$(echo "$issues_json" | jq \
    --arg title "Tenant not found in VMS: \`${VAST_TENANT_NAME}\`" \
    --arg details "No tenant named ${VAST_TENANT_NAME} matched cluster ${VAST_CLUSTER_NAME} in /api/tenants/." \
    --argjson severity 3 \
    --arg next_steps "Verify VAST_TENANT_NAME and VAST_CLUSTER_NAME qualifiers match VMS tenant records." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')"
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

views_resp="$(vast_fetch_json_api "/views/?tenant_name=${VAST_TENANT_NAME}")"
views_code="$(vast_fetch_http_code "$views_resp")"
views_body="$(vast_fetch_body "$views_resp")"

quotas_resp="$(vast_fetch_json_api "/quotas/?tenant_name=${VAST_TENANT_NAME}")"
quotas_code="$(vast_fetch_http_code "$quotas_resp")"
quotas_body="$(vast_fetch_body "$quotas_resp")"

printf '%s' "$tenant_json" >/tmp/vast_tenant_config_check.json
printf '%s' "$views_body" >/tmp/vast_views_config.json
printf '%s' "$quotas_body" >/tmp/vast_quotas_config.json

echo "Tenant configuration loaded for ${VAST_TENANT_NAME} (views HTTP ${views_code}, quotas HTTP ${quotas_code})"

while IFS=$'\t' read -r title details severity; do
  [[ -z "$title" ]] && continue
  issues_json="$(echo "$issues_json" | jq \
    --arg title "$title" \
    --arg details "$details" \
    --argjson severity "$severity" \
    --arg next_steps "Review tenant policies in VMS: user/group mappings, export permissions, and quota definitions that may restrict client access or capacity." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')"
done < <(VAST_TENANT_NAME="$VAST_TENANT_NAME" python3 <<'PY'
import json

tenant = json.load(open("/tmp/vast_tenant_config_check.json"))
views_raw = open("/tmp/vast_views_config.json").read().strip()
quotas_raw = open("/tmp/vast_quotas_config.json").read().strip()

def as_list(raw):
    if not raw:
        return []
    data = json.loads(raw)
    if isinstance(data, list):
        return data
    return data.get("results", data.get("views", data.get("quotas", [])))

views = as_list(views_raw)
quotas = as_list(quotas_raw)

if tenant.get("enabled") is False or tenant.get("state") in ("disabled", "suspended"):
    print(f"Tenant disabled in VMS\tTenant `{tenant.get('name', tenant.get('tenant_name'))}` state={tenant.get('state', tenant.get('enabled'))}\t3")

qos = tenant.get("qos") or tenant.get("qos_policy") or {}
if isinstance(qos, dict) and qos.get("enabled") is False:
    print(f"Tenant QoS policy disabled\tQoS policy is disabled; workloads may hit cluster defaults unexpectedly.\t4")

for view in views:
    path = view.get("path") or view.get("name")
    policy = view.get("policy") or view.get("export_policy") or {}
    if policy.get("permission") in ("RO", "read_only", "READ_ONLY"):
        print(f"Read-only export policy on view `{path}`\tExport policy permission={policy.get('permission')} may block client writes.\t3")
    if view.get("blocked") or view.get("write_blocked"):
        print(f"View write blocked: `{path}`\tView reports blocked/write_blocked flag.\t3")

for quota in quotas:
    name = quota.get("name") or quota.get("path") or "quota"
    if quota.get("exceeded") or quota.get("is_exceeded"):
        print(f"Quota exceeded: `{name}`\tQuota exceeded flag set in VMS configuration.\t3")
    if quota.get("blocked_users_count", 0) or quota.get("blocked_user_count", 0):
        count = quota.get("blocked_users_count") or quota.get("blocked_user_count")
        print(f"Quota blocking users on `{name}`\tblocked_users_count={count}\t4")
PY
)

rm -f /tmp/vast_tenant_config_check.json /tmp/vast_views_config.json /tmp/vast_quotas_config.json

echo "$issues_json" >"$OUTPUT_FILE"
echo "Analysis completed. Results saved to $OUTPUT_FILE"
cat "$OUTPUT_FILE"
