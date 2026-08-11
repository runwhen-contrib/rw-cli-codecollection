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
printf '%s' "$products" | jq --arg org "$APIGEE_ORG" "$APIGEE_JQ_HELPERS"'
  def norm($v): ($v // "") | tostring | gsub("\\s"; "");
  def describe($p): (($p.name // "unknown")) as $n
    | (($p.displayName // "")) as $d
    | if ($d == "" or $d == $n) then $n else "\($n) (\($d))" end;

  # Group by condition, not by resource: the SLX is project-scoped, so each
  # condition is one issue listing every product that exhibits it.
  ([ .[] | select((.approvalType // "") == "auto") ]) as $auto
  | ([ .[] | select(norm(.quota) == "" or norm(.quota) == "0") ]) as $noquota
  |
  ( (if ($auto | length) > 0 then [{
        title: "API products permit auto-approval of access in org `\($org)`",
        details: "\($auto | length) API product(s) in org `\($org)` have approvalType `auto`, allowing developer apps to gain access without manual review. This weakens the access-control posture.\n\nAffected products:\n\(fmt_list($auto | map(describe(.))))",
        severity: 2,
        next_steps: "Review these products in the Apigee console and switch approvalType to `manual` unless self-service access is an explicit requirement.",
        expected: "API products should require manual approval unless auto-approval is intentional",
        actual: "\($auto | length) API product(s) use auto-approval: \(fmt_inline($auto | map(.name // "unknown")))",
        affected_count: ($auto | length),
        products: ($auto | map(.name // "unknown")),
        issue_type: "auto_approval"
      }] else [] end)
    +
    (if ($noquota | length) > 0 then [{
        title: "API products have no quota/rate limit configured in org `\($org)`",
        details: "\($noquota | length) API product(s) in org `\($org)` have no quota set, so no rate limit is enforced by the product. This can allow runaway usage or break intended limits.\n\nAffected products:\n\(fmt_list($noquota | map(describe(.) + " -- quota=" + ((.quota // "unset") | tostring))))",
        severity: 3,
        next_steps: "Confirm whether these products intentionally rely on a shared quota policy. If not, set an explicit quota (quota, quotaInterval, quotaTimeUnit) on each.",
        expected: "API products should define a non-zero quota so rate limits are enforced",
        actual: "\($noquota | length) API product(s) have no quota configured: \(fmt_inline($noquota | map(.name // "unknown")))",
        affected_count: ($noquota | length),
        products: ($noquota | map(.name // "unknown")),
        issue_type: "missing_quota"
      }] else [] end)
  )
' > "$ISSUES_FILE"

apigee_write_status "$STATUS_FILE"
echo "API product check complete. Evaluated $(printf '%s' "$products" | jq 'length') product(s), found $(jq 'length' "$ISSUES_FILE") issue(s)."
