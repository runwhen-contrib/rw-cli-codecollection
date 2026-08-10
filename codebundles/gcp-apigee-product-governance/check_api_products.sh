#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID  - GCP project owning the Apigee organization
#   APIGEE_ORG      - optional; resolved from GCP_PROJECT_ID when empty
#   APIPRODUCTS     - optional; comma-separated product names or 'All' (default)
#
# Flags API products that weaken or break the intended access-control/quota
# contract:
#   - auto-approval enabled (unapproved access allowed)            -> severity 2
#   - missing or zero quota / rate limit                           -> severity 3
#
# Writes api_products_issues.json and api_products_status.json.
# Always exits 0; an access failure is signalled through the status file so the
# SLI scores this dimension 0 rather than treating "no findings" as healthy.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/apigee_common.sh"

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
APIPRODUCTS="${APIPRODUCTS:-All}"
ISSUES_FILE="api_products_issues.json"
STATUS_FILE="api_products_status.json"

# --- Fail closed when the org cannot be resolved ------------------------------
org_rc=0
resolve_apigee_org || org_rc=$?
if [ "$org_rc" -eq 2 ]; then
  # The organization list was readable and this project has no Apigee
  # organization. Nothing to govern -- a healthy, informative result.
  apigee_finish_not_applicable "$ISSUES_FILE" "$STATUS_FILE"
  exit 0
elif [ "$org_rc" -ne 0 ]; then
  apigee_note_failure "Could not determine the Apigee organization for project $GCP_PROJECT_ID"
  echo '[]' > "$ISSUES_FILE"
  apigee_write_status "$STATUS_FILE"
  echo "API product check could not run: the Apigee organization could not be determined."
  exit 0
fi

echo "Checking API products in org: $APIGEE_ORG (project: $GCP_PROJECT_ID)"

if ! all_products="$(apigee_list_api_products)"; then
  echo '[]' > "$ISSUES_FILE"
  apigee_write_status "$STATUS_FILE"
  echo "API product check could not run: unable to list API products."
  exit 0
fi

# --- Build a filtered product list -------------------------------------------
if [ "$APIPRODUCTS" != "All" ] && [ -n "$APIPRODUCTS" ]; then
  filter="$(printf '%s' "$APIPRODUCTS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | jq -R . | jq -sc .)"
  products="$(printf '%s' "$all_products" | jq -c --argjson names "$filter" \
    '[.[] | select(.name as $n | $names | index($n) != null)]')"
else
  products="$all_products"
fi

# --- Evaluate every product in a single jq pass -------------------------------
# Doing this in jq rather than a shell read-loop means product names and display
# names containing quotes, backslashes or newlines cannot corrupt the output.
printf '%s' "$products" | jq --arg org "$APIGEE_ORG" '
  def norm($v): ($v // "") | tostring | gsub("\\s"; "");

  [ .[]
    | . as $p
    | (($p.name // "unknown")) as $name
    | (($p.displayName // $p.name // "unknown")) as $display
    | (norm($p.quota)) as $quota
    | (($p.quotaInterval // "")) as $interval
    | (($p.quotaTimeUnit // "")) as $unit
    | (
        (if (($p.approvalType // "") == "auto")
         then [{
           title: "API product `\($name)` permits auto-approval of access",
           details: "API product `\($display)` in org `\($org)` has approvalType `auto`, allowing developer apps to gain access without manual review. This weakens the access-control posture.",
           severity: 2,
           next_steps: "Review product `\($name)` in the Apigee console and switch approvalType to `manual` unless self-service access is an explicit requirement.",
           expected: "API products should require manual approval unless auto-approval is intentional",
           actual: "API product `\($name)` uses auto-approval",
           product: $name,
           issue_type: "auto_approval"
         }] else [] end)
        +
        (if ($quota == "" or $quota == "0")
         then [{
           title: "API product `\($name)` has no quota/rate limit configured",
           details: "API product `\($display)` in org `\($org)` has quota `\($p.quota // "unset")` (interval `\(if $interval == "" then "unset" else $interval end)`, unit `\(if $unit == "" then "unset" else $unit end)`), so no rate limit is enforced by this product. This can allow runaway usage or break intended limits.",
           severity: 3,
           next_steps: "Confirm whether the product intentionally relies on a shared quota policy. If not, set an explicit quota (quota, quotaInterval, quotaTimeUnit) on product `\($name)`.",
           expected: "API products should define a non-zero quota so rate limits are enforced",
           actual: "API product `\($name)` has no quota configured",
           product: $name,
           issue_type: "missing_quota"
         }] else [] end)
      )
  ] | flatten
' > "$ISSUES_FILE"

apigee_write_status "$STATUS_FILE"
echo "API product check complete. Evaluated $(printf '%s' "$products" | jq 'length') product(s), found $(jq 'length' "$ISSUES_FILE") issue(s)."
