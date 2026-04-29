#!/usr/bin/env bash
# Report on the project's domain configuration via GET /v9/projects/{id}/domains.
# Surfaces production hostnames with their verification + redirect state and
# raises issues for unverified production domains (the #1 cause of "site loads
# on the *.vercel.app alias but not on our custom domain").
#
# Outputs to $VERCEL_ARTIFACT_DIR (default `.`):
#   vercel_project_domains.json          — full /v9/.../domains response (all targets)
#   vercel_project_domains_issues.json   — issues array for the runbook
#
# stdout: a markdown report block embedded in the runbook report.
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=vercel-helpers.sh
source "${SCRIPT_DIR}/vercel-helpers.sh"

vercel_artifact_prepare
ARTIFACT_DIR="$(vercel_artifact_dir)"
OUT_FILE="${ARTIFACT_DIR}/vercel_project_domains.json"
ISSUES_FILE="${ARTIFACT_DIR}/vercel_project_domains_issues.json"
ERR_FILE="$(mktemp)"
trap 'rm -f "$ERR_FILE" 2>/dev/null || true' EXIT

PROJECT_RAW="${VERCEL_PROJECT_ID:?VERCEL_PROJECT_ID required}"
PROJECT_ID="$(vercel_resolve_project_id_cached)" || PROJECT_ID="$PROJECT_RAW"

echo "## Vercel project domains"
echo
echo "- **Project:** \`${PROJECT_RAW}\` → \`${PROJECT_ID}\`"
echo "- **Endpoint:** \`GET /v9/projects/{id}/domains\`"
echo

echo '[]' >"$OUT_FILE"
echo '[]' >"$ISSUES_FILE"

if ! vercel_py list-project-domains \
       --project-id "$PROJECT_ID" \
       --error-out "$ERR_FILE" \
       --out "$OUT_FILE" 2>>"$ERR_FILE"; then
  blob="$(head -c 600 "$ERR_FILE" | sed 's/[[:cntrl:]]//g')"
  jq -n --arg t "Could not list domains for Vercel project \`${PROJECT_RAW}\`" \
        --arg d "GET /v9/projects/{id}/domains failed. First ~600 bytes of the error: ${blob}" \
        --arg n "Verify the token has read access to the project's domains and re-run." \
        '[{severity: 3, title: $t, details: $d, next_steps: $n}]' >"$ISSUES_FILE"
  echo "**Status:** API call failed — see issue."
  echo
  echo '```'
  echo "$blob"
  echo '```'
  exit 0
fi

TOTAL="$(jq 'length' "$OUT_FILE" 2>/dev/null || echo 0)"
TOTAL="${TOTAL:-0}"

if [[ "$TOTAL" == "0" ]]; then
  echo "_No domains attached to this project (auto-generated *.vercel.app aliases are always managed by Vercel and not returned here)._"
  exit 0
fi

# Split production-bound (no gitBranch + no customEnvironmentId) from preview/custom-env.
PROD_FILTER='map(select(.gitBranch == null and .customEnvironmentId == null))'
PREVIEW_FILTER='map(select(.gitBranch != null or .customEnvironmentId != null))'

PROD_TOTAL="$(jq "$PROD_FILTER | length" "$OUT_FILE")"
PROD_VERIFIED="$(jq "$PROD_FILTER | map(select(.verified != false)) | length" "$OUT_FILE")"
PROD_UNVERIFIED="$(jq "$PROD_FILTER | map(select(.verified == false)) | length" "$OUT_FILE")"
PREVIEW_TOTAL="$(jq "$PREVIEW_FILTER | length" "$OUT_FILE")"

echo "- **Total domains:** ${TOTAL} (${PROD_TOTAL} production-bound, ${PREVIEW_TOTAL} preview / custom-env)"
echo "- **Production verified / unverified:** ${PROD_VERIFIED} / ${PROD_UNVERIFIED}"
echo

if [[ "$PROD_TOTAL" -gt 0 ]]; then
  echo "### Production domains"
  echo
  echo "| Verified | Name | Apex | Redirect | Created |"
  echo "| --- | --- | --- | --- | --- |"
  jq -r "
    def fmt_ts(ms): if (ms // 0) <= 0 then \"-\" else (ms / 1000 | strftime(\"%Y-%m-%d\")) end;
    $PROD_FILTER
    | sort_by(.name)
    | .[]
    | \"| \(if .verified == false then \"❌ no\" else \"✅ yes\" end) | \(.name) | \(.apexName // \"-\") | \(.redirect // \"-\") | \(fmt_ts(.createdAt)) |\"
  " "$OUT_FILE"
  echo
fi

if [[ "$PREVIEW_TOTAL" -gt 0 ]]; then
  echo "### Preview / custom-environment domains"
  echo
  echo "| Name | Branch | Custom env | Verified |"
  echo "| --- | --- | --- | --- |"
  jq -r "
    $PREVIEW_FILTER
    | sort_by(.name)
    | .[]
    | \"| \(.name) | \(.gitBranch // \"-\") | \(.customEnvironmentId // \"-\") | \(if .verified == false then \"❌ no\" else \"✅ yes\" end) |\"
  " "$OUT_FILE"
  echo
fi

# Build issues for unverified production domains (one issue per domain so each
# carries its own next-steps with the actual TXT/CNAME records to add).
if [[ "$PROD_UNVERIFIED" -gt 0 ]]; then
  jq -c "
    $PROD_FILTER
    | map(select(.verified == false))
    | map({
        severity: 3,
        title: (\"Production domain \\\"\(.name)\\\" not verified on Vercel project \`${PROJECT_RAW}\`\"),
        details: (
          \"Domain \(.name) is attached to the project but Vercel reports verified=false. Until verified, requests to this domain do not reach the deployment. Pending verification records:\\n\" +
          ((.verification // [])
            | map(\"- \(.type) \(.domain) -> \(.value)\")
            | join(\"\\n\")
            | (if . == \"\" then \"(none returned by Vercel — try removing/re-adding the domain in the dashboard)\" else . end))
        ),
        next_steps: (
          \"Add the verification record(s) above at your DNS provider, then click 'Refresh' on the domain in the Vercel dashboard. If you control the apex, you can also use Vercel nameservers.\"
        )
      })
  " "$OUT_FILE" >"$ISSUES_FILE"
fi
