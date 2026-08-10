#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID  - GCP project owning the Apigee organization
#   APIGEE_ORG      - optional; resolved from GCP_PROJECT_ID when empty
#
# Discovers the org-wide entitlement surface of an Apigee X organization:
# API products, developers and developer apps (with their consumer keys).
#
# Writes:
#   entitlements_discovery.json         - discovery snapshot
#   entitlements_discovery_issues.json  - JSON array of issues (empty when the
#                                         org was enumerated successfully)
#   entitlements_discovery_status.json  - {"access_ok":bool,"reason":string}
#
# Always exits 0: an access failure is reported as an issue, not as a crash.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/apigee_common.sh"

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
ISSUES_FILE="entitlements_discovery_issues.json"
STATUS_FILE="entitlements_discovery_status.json"
SNAPSHOT_FILE="entitlements_discovery.json"

: > "$ISSUES_FILE"

org_label="${APIGEE_ORG:-<unresolved>}"

# --- Resolve the organization -------------------------------------------------
org_rc=0
resolve_apigee_org || org_rc=$?

if [ "$org_rc" -eq 2 ]; then
  # The organization list was readable and no organization is bound to this
  # project. The project does not use Apigee: not a failure, and not an issue.
  echo '[]' > "$ISSUES_FILE"
  apigee_write_status "$STATUS_FILE"
  jq -n --arg p "$GCP_PROJECT_ID" \
    '{org:null, project_id:$p, access_ok:true, apigee_present:false,
      api_product_count:0, developer_count:0, app_count:0,
      api_products:[], developers:[], apps:[]}' > "$SNAPSHOT_FILE"
  echo "No Apigee organization is bound to project $GCP_PROJECT_ID; nothing to discover."
  exit 0
fi

if [ "$org_rc" -ne 0 ]; then
  apigee_note_failure "Could not determine the Apigee organization for project $GCP_PROJECT_ID"
  apigee_issue \
    "Cannot Determine Apigee Organization for Project \`$GCP_PROJECT_ID\`" \
    "The Apigee organization list could not be read for project \`$GCP_PROJECT_ID\`, so whether this project has an Apigee organization is unknown. Governance checks cannot run and are scored 0 rather than healthy." \
    2 \
    "Verify the service account holds roles/apigee.readOnlyAdmin, or set APIGEE_ORG explicitly if the organization name is known." \
    "The Apigee organization list should be readable for project \`$GCP_PROJECT_ID\`" \
    "The Apigee organization list could not be read for project \`$GCP_PROJECT_ID\`" \
    "$(jq -cn --arg p "$GCP_PROJECT_ID" '{project_id:$p, issue_type:"discovery_access_error"}')" \
    >> "$ISSUES_FILE"

  jq -s '.' "$ISSUES_FILE" > "${ISSUES_FILE}.tmp" && mv "${ISSUES_FILE}.tmp" "$ISSUES_FILE"
  apigee_write_status "$STATUS_FILE"
  jq -n --arg p "$GCP_PROJECT_ID" \
    '{org:null, project_id:$p, access_ok:false, apigee_present:null,
      api_product_count:0, developer_count:0, app_count:0,
      api_products:[], developers:[], apps:[]}' > "$SNAPSHOT_FILE"
  echo "Discovery could not run: the Apigee organization for $GCP_PROJECT_ID could not be determined."
  exit 0
fi

org_label="$APIGEE_ORG"
echo "Discovering Apigee entitlements for org: $APIGEE_ORG (project: $GCP_PROJECT_ID)"

# add_access_issue <what> <next_steps>
add_access_issue() {
  apigee_issue \
    "Cannot Access $1 for org \`$APIGEE_ORG\`" \
    "The Apigee management API did not return $1 for org \`$APIGEE_ORG\` in project \`$GCP_PROJECT_ID\`. Governance checks over this data cannot run and are scored 0 rather than healthy." \
    2 \
    "$2" \
    "Apigee entitlements in org \`$APIGEE_ORG\` should be enumerable for governance checks" \
    "The Apigee management API did not return $1 for org \`$APIGEE_ORG\`" \
    "$(jq -cn --arg org "$APIGEE_ORG" --arg p "$GCP_PROJECT_ID" \
       '{org:$org, project_id:$p, issue_type:"discovery_access_error"}')" \
    >> "$ISSUES_FILE"
}

# --- List API products -------------------------------------------------------
if ! api_products="$(apigee_list_api_products)"; then
  api_products='[]'
  add_access_issue "API products" \
    "Verify the service account has roles/apigee.readOnlyAdmin on the organization and that the org name is correct."
fi

# --- List developers ----------------------------------------------------------
if ! developers="$(apigee_list_developers)"; then
  developers='[]'
  add_access_issue "developers" \
    "Verify the service account has roles/apigee.readOnlyAdmin on the organization."
elif apigee_developers_truncated "$developers"; then
  # developers.list cannot combine expand with pagination, so the expanded list
  # stops at 1000. Report it rather than silently analysing a partial org.
  apigee_issue \
    "Developer list for org \`$APIGEE_ORG\` is truncated at $APIGEE_PAGE_SIZE records" \
    "The Apigee developers.list endpoint returned the maximum of $APIGEE_PAGE_SIZE expanded developers for org \`$APIGEE_ORG\`. The API rejects pagination parameters when expand=true, so developers beyond this cap were not evaluated and developer-status findings are incomplete." \
    3 \
    "Scope the analysis to specific developers or apps, or evaluate developer status through a paginated unexpanded listing plus per-developer lookups." \
    "The full developer list should be evaluable for org \`$APIGEE_ORG\`" \
    "Only the first $APIGEE_PAGE_SIZE developers in org \`$APIGEE_ORG\` were evaluated" \
    "$(jq -cn --arg org "$APIGEE_ORG" '{org:$org, issue_type:"developer_list_truncated"}')" \
    >> "$ISSUES_FILE"
fi

# --- List developer apps (org-scope, expanded, with credentials) --------------
if ! apps="$(apigee_list_apps)"; then
  apps='[]'
  add_access_issue "developer apps" \
    "Verify the service account has roles/apigee.readOnlyAdmin on the organization."
fi

product_count="$(printf '%s' "$api_products" | jq 'length')"
developer_count="$(printf '%s' "$developers" | jq 'length')"
app_count="$(printf '%s' "$apps" | jq 'length')"

# --- Write outputs ------------------------------------------------------------
if [ -s "$ISSUES_FILE" ]; then
  jq -s '.' "$ISSUES_FILE" > "${ISSUES_FILE}.tmp" && mv "${ISSUES_FILE}.tmp" "$ISSUES_FILE"
else
  echo '[]' > "$ISSUES_FILE"
fi

apigee_write_status "$STATUS_FILE"

jq -n \
  --arg org "$org_label" \
  --arg project_id "$GCP_PROJECT_ID" \
  --argjson access_ok "$(apigee_access_ok && echo true || echo false)" \
  --argjson api_products "$api_products" \
  --argjson developers "$developers" \
  --argjson apps "$apps" \
  '{org:$org, project_id:$project_id, access_ok:$access_ok,
    api_product_count:($api_products|length),
    developer_count:($developers|length),
    app_count:($apps|length),
    api_products:$api_products, developers:$developers, apps:$apps}' > "$SNAPSHOT_FILE"

echo "Discovery complete."
echo "  API products: $product_count"
echo "  Developers:   $developer_count"
echo "  Apps:         $app_count"
echo "Issues detected: $(jq 'length' "$ISSUES_FILE")"
apigee_access_ok || echo "WARNING: one or more listings could not be read; downstream dimensions score 0."
