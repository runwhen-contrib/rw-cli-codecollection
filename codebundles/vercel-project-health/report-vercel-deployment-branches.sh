#!/usr/bin/env bash
# Recent deployments with git branch metadata + production/preview health
# hints. The Robot caller (runbook.robot::Report Vercel Deployment Branches
# Worker) resolves the project slug and calls GET /v6/deployments via the
# `Vercel` Python keyword library, then drops the response at
# $VERCEL_DEPLOYMENTS_RAW_PATH. This script reads that file and produces:
#
#   $VERCEL_ARTIFACT_DIR/vercel_deployments_snapshot.json         — sliced + summarized
#   $VERCEL_ARTIFACT_DIR/vercel_deployments_snapshot_issues.json  — content issues
#                                                                   (zero deployments,
#                                                                   latest prod not READY)
#   stdout                                                         — markdown report
set -uo pipefail

: "${VERCEL_PROJECT_ID:?Must set VERCEL_PROJECT_ID}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vercel-helpers.sh
source "${SCRIPT_DIR}/vercel-helpers.sh"

vercel_artifact_prepare
ARTIFACT_DIR="$(vercel_artifact_dir)"
RAW_PATH="${VERCEL_DEPLOYMENTS_RAW_PATH:-${ARTIFACT_DIR}/vercel_deployments_raw.json}"
ISSUES_FILE="${ARTIFACT_DIR}/vercel_deployments_snapshot_issues.json"
OUT_JSON="${ARTIFACT_DIR}/vercel_deployments_snapshot.json"
LIMIT="${DEPLOYMENT_SNAPSHOT_LIMIT:-25}"
issues_json='[]'
echo "$issues_json" >"$ISSUES_FILE"
echo '{"error":"not_run","deployments":[],"summary":{}}' >"$OUT_JSON"

if [[ "${VERCEL_API_STATUS:-ok}" != "ok" ]]; then
  echo '{"error":"'"${VERCEL_API_STATUS:-ok}"'","deployments":[],"summary":{}}' >"$OUT_JSON"
  echo "## Recent deployments — \`${VERCEL_PROJECT_ID}\`"
  echo
  echo "_API call did not complete (${VERCEL_API_STATUS:-ok}); see the runbook issue panel for details._"
  exit 0
fi

if [[ ! -s "$RAW_PATH" ]]; then
  echo '{"error":"missing_input","deployments":[],"summary":{}}' >"$OUT_JSON"
  echo "## Recent deployments — \`${VERCEL_PROJECT_ID}\`"
  echo
  echo "_Deployments JSON not found at \`${RAW_PATH}\` — Robot did not produce input._"
  exit 0
fi

jq --argjson lim "$LIMIT" --arg pid "${VERCEL_PROJECT_ID}" '
  def created_ms(d): ((d.createdAt // d.created // 0) | tonumber);
  def tgt(d): (d.target // "preview");
  def git_branch(d): (d.meta.gitBranch // d.meta.githubCommitRef // null);
  (.deployments // [])
  | map(select(. != null))
  | map({
      uid,
      url,
      readyState: (.readyState // .state // ""),
      target: tgt(.),
      createdAt: created_ms(.),
      name,
      gitBranch: git_branch(.),
      gitCommitSha: (.meta.githubCommitSha // null),
      gitCommitMessage: (.meta.githubCommitMessage // null),
      alias: ((.alias // []) | .[0:8])
    })
  | sort_by(-.createdAt)
  | . as $all
  | ($all[0:($lim | tonumber)]) as $slice
  | ($all | map(select(.target == "production")) | sort_by(-.createdAt) | .[0]) as $latest_prod
  | {
      project_id: $pid,
      generated_ms: (now * 1000 | floor),
      limit: ($lim | tonumber),
      summary: {
        total_listed: ($slice | length),
        latest_production: ($latest_prod // null),
        latest_production_ready: (
          ($all | map(select(.target == "production" and .readyState == "READY")) | sort_by(-.createdAt) | .[0]) // null
        ),
        preview_branch_sample: (
          [$all[] | select(.target != "production") | .gitBranch] | map(select(. != null)) | unique | .[0:20]
        ),
        not_ready_in_sample: [$slice[] | select(.readyState != "READY")] | length,
        production_missing_git_branch: (
          if $latest_prod == null then false else ($latest_prod.gitBranch == null) end
        )
      },
      deployments: $slice
    }
' "$RAW_PATH" >"$OUT_JSON"

dep_count="$(jq -r '.deployments | length' "$OUT_JSON")"
if [[ "$dep_count" -eq 0 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg t "No deployments returned for Vercel project \`${VERCEL_PROJECT_ID}\`" \
    --arg d "The deployments list was empty; branch information cannot be shown." \
    --argjson sev 3 \
    --arg n "Deploy the project or verify the project ID and team scope." \
    '. += [{title:$t, details:$d, severity:$sev, next_steps:$n}]')
fi

if jq -e '.summary.latest_production != null and (.summary.latest_production.readyState != "READY")' "$OUT_JSON" >/dev/null 2>&1; then
  ps="$(jq -c '.summary.latest_production' "$OUT_JSON")"
  issues_json=$(echo "$issues_json" | jq \
    --arg t "Latest production deployment not READY for \`${VERCEL_PROJECT_ID}\`" \
    --arg d "Newest production deployment is not READY: ${ps}" \
    --argjson sev 3 \
    --arg n "Inspect the deployment in Vercel (build logs, domains) and fix failing checks." \
    '. += [{title:$t, details:$d, severity:$sev, next_steps:$n}]')
fi

echo "$issues_json" >"$ISSUES_FILE"

# Markdown report → stdout
jq -r --arg pid "${VERCEL_PROJECT_ID}" --arg out "${OUT_JSON}" '
  def fmt_ts(ms):
    if (ms // 0) == 0 then "-"
    else ((ms | tonumber) / 1000 | strftime("%Y-%m-%dT%H:%M:%SZ")) end;
  def short_sha(s): if (s // "") == "" then "-" else (s | tostring)[0:8] end;
  def first_line(s): if (s // "") == "" then "-" else ((s | tostring) | split("\n")[0])[0:120] end;
  "### Recent deployments — \($pid)",
  "",
  (
    if (.summary.latest_production // null) == null
    then "- **Latest production:** _none_"
    else
      "- **Latest production:** `\(.summary.latest_production.uid)` — branch `\(.summary.latest_production.gitBranch // "-")` @ `\(short_sha(.summary.latest_production.gitCommitSha))`",
      "  - State: **\(.summary.latest_production.readyState)**",
      "  - URL: https://\(.summary.latest_production.url // "-")",
      "  - Created: \(fmt_ts(.summary.latest_production.createdAt))",
      "  - Commit: \(first_line(.summary.latest_production.gitCommitMessage))"
    end
  ),
  (
    if (.summary.latest_production_ready // null) != null and (.summary.latest_production_ready.uid != (.summary.latest_production.uid // ""))
    then
      "- **Latest production READY (different from above):** `\(.summary.latest_production_ready.uid)` — `\(.summary.latest_production_ready.gitBranch // "-")` @ `\(short_sha(.summary.latest_production_ready.gitCommitSha))` — \(fmt_ts(.summary.latest_production_ready.createdAt))"
    else empty
    end
  ),
  "- **Total in snapshot:** \(.summary.total_listed)",
  "- **Not READY in snapshot:** \(.summary.not_ready_in_sample)",
  "- **Production missing git branch:** \(.summary.production_missing_git_branch)",
  "",
  "#### Deployments (most recent first, limit \(.limit))",
  "",
  "| When (UTC) | Target | State | Branch | SHA | UID | URL |",
  "| --- | --- | --- | --- | --- | --- | --- |",
  ( .deployments[]
    | "| \(fmt_ts(.createdAt)) | \(.target) | \(.readyState) | \(.gitBranch // "-") | \(short_sha(.gitCommitSha)) | `\(.uid)` | \(if (.url // "") == "" then "-" else "https://\(.url)" end) |"
  ),
  "",
  (
    if ((.summary.preview_branch_sample // []) | length) == 0
    then "_No preview branches in snapshot._"
    else "**Preview branches (sample, up to 20):** " + ((.summary.preview_branch_sample // []) | join(", "))
    end
  ),
  "",
  "Artifact: `\($out)`"
' "$OUT_JSON"
