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
  # INTERIM: positive determination of absence -- either the organization list
  # was readable and holds nothing for this project, or the Apigee API has never
  # been enabled here. Both are definite answers, so this is not a failure and
  # raises no issue. A failed lookup never reaches this branch.
  #
  # The snapshot is a well-formed EMPTY topology, not {}: downstream jq reads
  # real empty collections rather than nulls, so `.api_products[]` iterates zero
  # times instead of aborting with "Cannot iterate over null".
  apigee_finish_not_applicable "$ISSUES_FILE" "$STATUS_FILE"
  jq -n --arg p "$GCP_PROJECT_ID" --arg reason "${APIGEE_ABSENCE_REASON:-}" \
    '{org:null, project_id:$p, access_ok:true, applicable:false,
      absence_reason:$reason,
      api_product_count:0, developer_count:0, app_count:0,
      api_products:[], developers:[], apps:[], environments:[]}' > "$SNAPSHOT_FILE"
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
    '{org:null, project_id:$p, access_ok:false, applicable:null,
      absence_reason:null,
      api_product_count:0, developer_count:0, app_count:0,
      api_products:[], developers:[], apps:[], environments:[]}' > "$SNAPSHOT_FILE"
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
fi
# Truncation of the developer list is reported by check_developer_status.sh,
# which owns developer findings and can say which of its results are affected.

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
    applicable:true, absence_reason:null,
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
