#!/usr/bin/env bash
# Resolve the deployments that overlap a lookback window so log queries use
# relevant deployment ids. The Robot caller (runbook.robot::Resolve Vercel
# Deployments In Window Worker) already:
#   - resolved the project slug,
#   - listed deployments via the `Vercel` Python keyword library,
#   - selected window-overlapping uids via the same library,
# and dropped:
#   $VERCEL_DEPLOYMENTS_RAW_PATH        — raw GET /v6/deployments response
#   $VERCEL_WINDOW_IDS_PATH             — {"deployment_ids":[...]}
#   $VERCEL_WIN_START_MS / $VERCEL_WIN_END_MS — window bounds in ms
#
# This script reads those files, joins ids back to their deployment metadata,
# writes the consolidated context artifact, and emits the markdown report.
set -uo pipefail

: "${VERCEL_PROJECT_ID:?Must set VERCEL_PROJECT_ID}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vercel-helpers.sh
source "${SCRIPT_DIR}/vercel-helpers.sh"

vercel_artifact_prepare
ARTIFACT_DIR="$(vercel_artifact_dir)"
RAW_PATH="${VERCEL_DEPLOYMENTS_RAW_PATH:-${ARTIFACT_DIR}/vercel_deployments_raw.json}"
IDS_PATH="${VERCEL_WINDOW_IDS_PATH:-${ARTIFACT_DIR}/vercel_deployments_in_window.json}"
ISSUES_FILE="${ARTIFACT_DIR}/vercel_resolve_issues.json"
CONTEXT_FILE="${ARTIFACT_DIR}/vercel_deployments_context.json"

DEPLOYMENT_ENVIRONMENT_LC="$(printf '%s' "${DEPLOYMENT_ENVIRONMENT:-production}" | tr '[:upper:]' '[:lower:]')"
issues_json='[]'
echo "$issues_json" >"$ISSUES_FILE"
echo '{"deployment_ids":[],"window":{},"project_id":""}' >"$CONTEXT_FILE"
trap 'echo "$issues_json" >"$ISSUES_FILE"' EXIT

if [[ "${VERCEL_API_STATUS:-ok}" != "ok" ]]; then
  echo "## Deployments resolved for log scan — \`${VERCEL_PROJECT_ID}\`"
  echo
  echo "_API call did not complete (${VERCEL_API_STATUS:-ok}); see the runbook issue panel for details._"
  exit 0
fi

WIN_START_MS="${VERCEL_WIN_START_MS:-0}"
WIN_END_MS="${VERCEL_WIN_END_MS:-0}"

# Robot wrote {"deployment_ids":[...]}; default to empty when missing.
if [[ -s "$IDS_PATH" ]]; then
  ids_json="$(jq -c '.deployment_ids // []' "$IDS_PATH" 2>/dev/null || echo '[]')"
else
  ids_json='[]'
fi
[[ -z "$ids_json" ]] && ids_json='[]'
dep_count="$(printf '%s' "$ids_json" | jq -r 'length' 2>/dev/null || echo 0)"

# Join chosen uids back to their full deployment metadata for the report.
detail_json='[]'
if [[ -s "$RAW_PATH" ]]; then
  detail_json="$(jq -c --argjson ids "$ids_json" '
    def short_sha(s): if (s // "") == "" then "-" else (s | tostring)[0:8] end;
    def created_ms(d): ((d.createdAt // d.created // 0) | tonumber);
    [ (.deployments // [])[]
      | select(.uid as $u | $ids | index($u) != null)
      | {
          uid,
          createdAt: created_ms(.),
          target: (.target // "preview"),
          readyState: (.readyState // .state // ""),
          gitBranch: (.meta.gitBranch // .meta.githubCommitRef // null),
          gitCommitSha: (.meta.githubCommitSha // null),
          url: (.url // "")
        }
    ] | sort_by(-.createdAt)
  ' "$RAW_PATH" 2>/dev/null || echo '[]')"
fi

jq -n \
  --argjson ids "$ids_json" \
  --argjson detail "$detail_json" \
  --argjson ws "$WIN_START_MS" \
  --argjson we "$WIN_END_MS" \
  --arg env "${DEPLOYMENT_ENVIRONMENT_LC}" \
  --arg pid "${VERCEL_PROJECT_ID}" \
  '{
    deployment_ids: $ids,
    deployments: $detail,
    window: {start_ms: $ws, end_ms: $we, environment: $env},
    project_id: $pid
  }' >"$CONTEXT_FILE"

if [[ "$dep_count" -eq 0 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg t "No Vercel deployment covers lookback window for \`${VERCEL_PROJECT_ID}\`" \
    --arg d "No READY deployments in ${DEPLOYMENT_ENVIRONMENT_LC} overlap [${WIN_START_MS}, ${WIN_END_MS}] ms." \
    --argjson sev 3 \
    --arg n "Deploy to the selected environment, widen TIME_WINDOW_HOURS, set DEPLOYMENT_ENVIRONMENT=all, or verify the project has recent traffic." \
    '. += [{title:$t, details:$d, severity:$sev, next_steps:$n}]')
fi

# Markdown report → stdout
ws_iso="$(vercel_md_fmt_ms "$WIN_START_MS")"
we_iso="$(vercel_md_fmt_ms "$WIN_END_MS")"
{
  printf '### Deployments resolved for log scan — %s\n\n' "$VERCEL_PROJECT_ID"
  echo "- **Window:** ${ws_iso} → ${we_iso} (${TIME_WINDOW_HOURS:-24}h, ${DEPLOYMENT_ENVIRONMENT_LC})"
  echo "- **Resolved deployments:** ${dep_count} (cap ${MAX_DEPLOYMENTS_TO_SCAN:-10})"
  echo "- **Project id:** \`${VERCEL_PROJECT_ID}\`"
  echo
  if [[ "$dep_count" -gt 0 ]]; then
    printf '| Created (UTC) | Target | State | Branch | SHA | UID | URL |\n'
    printf '| --- | --- | --- | --- | --- | --- | --- |\n'
    echo "$detail_json" | jq -r '
      def fmt_ts(ms): if (ms // 0) == 0 then "-" else (ms / 1000 | strftime("%Y-%m-%dT%H:%M:%SZ")) end;
      def short_sha(s): if (s // "") == "" then "-" else (s | tostring)[0:8] end;
      .[] | "| \(fmt_ts(.createdAt)) | \(.target) | \(.readyState) | \(.gitBranch // "-") | \(short_sha(.gitCommitSha)) | `\(.uid)` | \(if (.url // "") == "" then "-" else "https://\(.url)" end) |"
    '
  else
    printf '_No READY deployments overlap this window._\n'
  fi
  printf '\nContext: `%s`\n' "$CONTEXT_FILE"
}
