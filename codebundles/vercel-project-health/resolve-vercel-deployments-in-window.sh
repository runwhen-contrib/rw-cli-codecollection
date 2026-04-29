#!/usr/bin/env bash
# Resolve Vercel deployments whose active interval overlaps the lookback window.
set -uo pipefail

: "${VERCEL_PROJECT_ID:?Must set VERCEL_PROJECT_ID}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vercel-helpers.sh
source "${SCRIPT_DIR}/vercel-helpers.sh"

TOKEN="$(vercel_token_value)"
: "${TOKEN:?Must set VERCEL_TOKEN or vercel_token secret}"
export DEPLOYMENT_ENVIRONMENT="$(printf '%s' "${DEPLOYMENT_ENVIRONMENT:-production}" | tr '[:upper:]' '[:lower:]')"

vercel_artifact_prepare
ARTIFACT_DIR="$(vercel_artifact_dir)"
ISSUES_FILE="${ARTIFACT_DIR}/vercel_resolve_issues.json"
CONTEXT_FILE="${ARTIFACT_DIR}/vercel_deployments_context.json"

# Always overwrite outputs; trap guarantees the issues file reflects the final state.
issues_json='[]'
echo "$issues_json" >"$ISSUES_FILE"
echo '{"deployment_ids":[],"window":{},"project_id":""}' >"$CONTEXT_FILE"
trap 'echo "$issues_json" >"$ISSUES_FILE"' EXIT

vercel_compute_window_ms

# Resolve project id (slug → prj_…).
err_tmp="$(mktemp)"; resolve_tmp="$(mktemp)"
if ! vercel_py resolve-project-id --project-id "${VERCEL_PROJECT_ID}" \
        --error-out "$err_tmp" --out "$resolve_tmp" 2>>"$err_tmp"; then
  blob="$(cat "$err_tmp")"
  issues_json=$(jq -n \
    --arg t "$(vercel_resolve_issue_title "$blob" "${VERCEL_PROJECT_ID}")" \
    --arg d "$blob" \
    --arg n "$(vercel_resolve_issue_next_steps "$blob")" \
    --argjson sev 4 \
    '[{title:$t, details:$d, severity:$sev, next_steps:$n}]')
  rm -f "$err_tmp" "$resolve_tmp"
  exit 0
fi
PRJ_ID="$(jq -r '.id' "$resolve_tmp")"
rm -f "$err_tmp" "$resolve_tmp"

# List deployments via Python (handles pagination, retries, HTTP/1.1).
err_tmp="$(mktemp)"; deps_tmp="$(mktemp)"
if ! vercel_py list-deployments --project-id "$PRJ_ID" \
        --target "${DEPLOYMENT_ENVIRONMENT}" \
        --error-out "$err_tmp" --out "$deps_tmp" 2>>"$err_tmp"; then
  blob="$(cat "$err_tmp")"
  if printf '%s' "$blob" | grep -q 'invalidToken'; then
    next="$(vercel_resolve_issue_next_steps "$blob")"
  else
    next='Confirm VERCEL_TEAM_ID matches the owning team and that the token can list deployments for this project.'
  fi
  issues_json=$(jq -n \
    --arg t "Cannot list Vercel deployments for project \`${VERCEL_PROJECT_ID}\`" \
    --arg d "$blob" \
    --arg n "$next" \
    --argjson sev 4 \
    '[{title:$t, details:$d, severity:$sev, next_steps:$n}]')
  rm -f "$err_tmp" "$deps_tmp"
  exit 0
fi
rm -f "$err_tmp"

# Pick deployment uids overlapping [WIN_START_MS, WIN_END_MS].
ids_tmp="$(mktemp)"
if ! vercel_py select-deployments-for-window \
        --input "$deps_tmp" \
        --window-start-ms "$WIN_START_MS" --window-end-ms "$WIN_END_MS" \
        --environment "${DEPLOYMENT_ENVIRONMENT}" \
        --max-results "${MAX_DEPLOYMENTS_TO_SCAN:-10}" \
        --out "$ids_tmp"; then
  ids_json='[]'
else
  ids_json="$(jq -c '.deployment_ids // []' "$ids_tmp")"
fi
rm -f "$ids_tmp"
[[ -z "$ids_json" ]] && ids_json='[]'
dep_count="$(printf '%s' "$ids_json" | jq -r 'length' 2>/dev/null || echo 0)"

# Join chosen uids back to their full deployment metadata for the report.
detail_json='[]'
if [[ -f "$deps_tmp" ]]; then
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
  ' "$deps_tmp")"
fi
rm -f "$deps_tmp"

jq -n \
  --argjson ids "$ids_json" \
  --argjson detail "$detail_json" \
  --argjson ws "$WIN_START_MS" \
  --argjson we "$WIN_END_MS" \
  --arg env "${DEPLOYMENT_ENVIRONMENT}" \
  --arg pid "$PRJ_ID" \
  '{
    deployment_ids: $ids,
    deployments: $detail,
    window: {start_ms: $ws, end_ms: $we, environment: $env},
    project_id: $pid
  }' >"$CONTEXT_FILE"

if [[ "$dep_count" -eq 0 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg t "No Vercel deployment covers lookback window for \`${VERCEL_PROJECT_ID}\`" \
    --arg d "No READY deployments in ${DEPLOYMENT_ENVIRONMENT} overlap [${WIN_START_MS}, ${WIN_END_MS}] ms." \
    --argjson sev 3 \
    --arg n "Deploy to the selected environment, widen TIME_WINDOW_HOURS, set DEPLOYMENT_ENVIRONMENT=all, or verify the project has recent traffic." \
    '. += [{title:$t, details:$d, severity:$sev, next_steps:$n}]')
fi

# Markdown report → stdout
ws_iso="$(vercel_md_fmt_ms "$WIN_START_MS")"
we_iso="$(vercel_md_fmt_ms "$WIN_END_MS")"
{
  printf '### Deployments resolved for log scan — %s\n\n' "$VERCEL_PROJECT_ID"
  echo "- **Window:** ${ws_iso} → ${we_iso} (${TIME_WINDOW_HOURS:-24}h, ${DEPLOYMENT_ENVIRONMENT})"
  echo "- **Resolved deployments:** ${dep_count} (cap ${MAX_DEPLOYMENTS_TO_SCAN:-10})"
  echo "- **Project id:** \`${PRJ_ID}\`"
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
