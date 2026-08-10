#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID        - GCP project owning the Apigee organization
#   APIGEE_ORG            - optional; resolved from GCP_PROJECT_ID when empty
#   USAGE_LOOKBACK_DAYS   - optional; analytics lookback window (default 30)
#
# Identifies orphaned / unused entitlements for housekeeping (severity 4):
#   - API products with no developer app attached
#   - developer apps with no consumer keys
#   - developer apps with no recorded traffic (Analytics developer_app
#     dimension over the lookback window)
#
# Writes orphaned_entitlements_issues.json and orphaned_entitlements_status.json.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/apigee_common.sh"

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
USAGE_LOOKBACK_DAYS="${USAGE_LOOKBACK_DAYS:-30}"
ISSUES_FILE="orphaned_entitlements_issues.json"
STATUS_FILE="orphaned_entitlements_status.json"

org_rc=0
resolve_apigee_org || org_rc=$?
if [ "$org_rc" -eq 2 ]; then
  apigee_finish_not_applicable "$ISSUES_FILE" "$STATUS_FILE"
  exit 0
elif [ "$org_rc" -ne 0 ]; then
  apigee_note_failure "Could not determine the Apigee organization for project $GCP_PROJECT_ID"
  echo '[]' > "$ISSUES_FILE"
  apigee_write_status "$STATUS_FILE"
  echo "Orphaned-entitlement check could not run: the Apigee organization could not be determined."
  exit 0
fi

echo "Checking orphaned/unused entitlements in org: $APIGEE_ORG (project: $GCP_PROJECT_ID)"

if ! apps="$(apigee_list_apps)"; then
  echo '[]' > "$ISSUES_FILE"
  apigee_write_status "$STATUS_FILE"
  echo "Orphaned-entitlement check could not run: unable to list developer apps."
  exit 0
fi

if ! products="$(apigee_list_api_products)"; then
  echo '[]' > "$ISSUES_FILE"
  apigee_write_status "$STATUS_FILE"
  echo "Orphaned-entitlement check could not run: unable to list API products."
  exit 0
fi

# --- Apps with no consumer keys, and products no app references ---------------
# Note: the orphaned-product evaluation runs unconditionally. Gating it on
# "at least one product is referenced" would make the maximal-orphan case --
# no app references any product at all -- report zero findings.
structural_issues="$(jq -n \
  --argjson apps "$apps" \
  --argjson products "$products" \
  --arg org "$APIGEE_ORG" '
  ([ $apps[] | (.credentials // [])[] | (.apiProducts // [])[] | .apiproduct
     | select(. != null) ] | unique) as $referenced
  |
  ( [ $apps[]
      | . as $app
      | (($app.name // "unknown")) as $app_name
      | (($app.developerId // "unknown")) as $dev_id
      | select((($app.credentials // []) | length) == 0)
      | {
          title: "Developer app `\($app_name)` has no consumer keys",
          details: "Developer app `\($app_name)` (developer `\($dev_id)`) in org `\($org)` has no consumer keys/credentials attached, so it cannot consume any API product.",
          severity: 4,
          next_steps: "Verify the app is still needed. If it is not, remove app `\($app_name)`; if it should be active, generate a consumer key for it.",
          expected: "Developer apps should have at least one consumer key if they are intended for use",
          actual: "Developer app `\($app_name)` has no consumer keys",
          app: $app_name,
          issue_type: "app_no_keys"
        } ]
    +
    [ $products[]
      | . as $prod
      | (($prod.name // "unknown")) as $pname
      | select(($referenced | index($pname)) == null)
      | {
          title: "API product `\($pname)` is orphaned (no developer app attached)",
          details: "API product `\($pname)` in org `\($org)` is not referenced by any developer-app credential and can be considered for retirement.",
          severity: 4,
          next_steps: "Confirm the product is no longer needed by any consumer, then delete or archive product `\($pname)`.",
          expected: "API products should be referenced by at least one developer-app credential",
          actual: "API product `\($pname)` is not referenced by any developer app",
          product: $pname,
          issue_type: "orphaned_product"
        } ] )
')"

# --- Unused developer apps (Analytics developer_app cross-reference) ----------
# The Apigee stats endpoint wants an "MM/DD/YYYY HH:MM" timeRange. Computing the
# window start needs a date implementation that can do relative arithmetic:
# GNU date uses -d, BSD/macOS date uses -v. Try both, and if neither works,
# skip the cross-reference EXPLICITLY rather than falling back to a zero-width
# window that would silently report every app as unused.
start_gmt=""
if start_gmt="$(date -u -d "$USAGE_LOOKBACK_DAYS days ago" +"%m/%d/%Y %H:%M" 2>/dev/null)"; then
  :
elif start_gmt="$(date -u -v "-${USAGE_LOOKBACK_DAYS}d" +"%m/%d/%Y %H:%M" 2>/dev/null)"; then
  :
else
  start_gmt=""
fi

usage_checked="false"
usage_skip_reason=""
used_apps_file="$(mktemp)"
trap 'rm -f "$used_apps_file"' EXIT

if [ -z "$start_gmt" ]; then
  usage_skip_reason="no date implementation supporting relative arithmetic is available (tried GNU \`date -d\` and BSD \`date -v\`)"
elif ! env_payload="$(apigee_api_get "organizations/$APIGEE_ORG/environments" 2>/dev/null)"; then
  usage_skip_reason="the environments in org \`$APIGEE_ORG\` could not be listed"
else
  environments="$(printf '%s' "$env_payload" | jq -c 'if type == "array" then . else (.environment // []) end' 2>/dev/null || echo '[]')"
  env_count="$(printf '%s' "$environments" | jq 'length')"
  end_gmt="$(date -u +"%m/%d/%Y %H:%M")"
  tr_start="$(apigee_urlencode "$start_gmt")"
  tr_end="$(apigee_urlencode "$end_gmt")"

  env_failures=0
  while IFS= read -r env; do
    [ -z "$env" ] && continue
    if stats="$(apigee_api_get "organizations/$APIGEE_ORG/environments/$env/stats/developer_app?select=sum(message_count)&timeRange=$tr_start~$tr_end&timeUnit=month" 2>/dev/null)"; then
      # A stats body that does not parse yields no app names, which would mark
      # every app in this environment unused. Count it as an environment
      # failure so the cross-reference is skipped rather than wrong.
      if ! printf '%s' "$stats" \
        | jq -r '[ (.environments // [])[] | (.dimensions // [])[] | .name // empty ] | .[]' \
        >> "$used_apps_file" 2>/dev/null; then
        env_failures=$((env_failures + 1))
      fi
    else
      env_failures=$((env_failures + 1))
    fi
  done < <(printf '%s' "$environments" | jq -r '.[]')

  if [ "$env_count" -eq 0 ]; then
    usage_skip_reason="org \`$APIGEE_ORG\` reported no environments to query for analytics"
  elif [ "$env_failures" -gt 0 ]; then
    # Partial analytics data would mark every app in the unreadable
    # environments as unused, so a partial result is treated as no result.
    usage_skip_reason="$env_failures of $env_count environment(s) returned no analytics data"
  else
    sort -u "$used_apps_file" -o "$used_apps_file"
    usage_checked="true"
  fi
fi

if [ "$usage_checked" = "true" ]; then
  usage_issues="$(jq -n \
    --argjson apps "$apps" \
    --arg org "$APIGEE_ORG" \
    --argjson days "$USAGE_LOOKBACK_DAYS" \
    --rawfile used "$used_apps_file" '
    ($used | split("\n") | map(select(. != ""))) as $used_apps
    | [ $apps[]
        | (((.name) // "unknown")) as $app_name
        | select(($used_apps | index($app_name)) == null)
        | {
            title: "Developer app `\($app_name)` is unused (no traffic in \($days) days)",
            details: "Developer app `\($app_name)` in org `\($org)` recorded no API traffic in the last \($days) day(s) according to the Analytics developer_app dimension.",
            severity: 4,
            next_steps: "Confirm whether app `\($app_name)` is still required. If not, remove it to reduce the entitlement surface; if expected traffic is missing, investigate.",
            expected: "Developer apps should see traffic within the lookback window if they are actively used",
            actual: "Developer app `\($app_name)` saw no traffic in the lookback window",
            app: $app_name,
            issue_type: "unused_app"
          } ]
  ')"
else
  # The cross-reference could not run. Report that as a finding of its own so
  # a degraded check is never indistinguishable from a clean one -- silently
  # skipping would let a permanently broken analytics permission read as "no
  # unused apps" forever.
  echo "Analytics usage cross-reference skipped: $usage_skip_reason."
  usage_issues="$(jq -n \
    --arg org "$APIGEE_ORG" \
    --arg reason "$usage_skip_reason" \
    --argjson days "$USAGE_LOOKBACK_DAYS" '
    [{
      title: "Analytics usage cross-reference could not run for org `\($org)`",
      details: "Unused-app detection over the last \($days) day(s) was skipped because \($reason). Orphaned products and keyless apps were still evaluated, but apps that receive no traffic cannot be identified until this is resolved.",
      severity: 4,
      next_steps: "Grant the service account roles/apigee.analyticsViewer on org `\($org)` and confirm the environments are readable, then re-run the check.",
      expected: "Analytics developer_app statistics should be readable so unused apps can be identified",
      actual: "The analytics cross-reference was skipped: \($reason)",
      org: $org,
      issue_type: "usage_check_unavailable"
    }]
  ')"
fi

jq -n --argjson a "$structural_issues" --argjson b "$usage_issues" '$a + $b' > "$ISSUES_FILE"

apigee_write_status "$STATUS_FILE"
echo "Orphaned/unused entitlement check complete. Found $(jq 'length' "$ISSUES_FILE") issue(s)."
