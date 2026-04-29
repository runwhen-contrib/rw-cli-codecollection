#!/usr/bin/env bash
# Fetch Vercel project metadata (safe fields only; no secret env values).
set -uo pipefail

: "${VERCEL_PROJECT_ID:?Must set VERCEL_PROJECT_ID}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vercel-helpers.sh
source "${SCRIPT_DIR}/vercel-helpers.sh"

vercel_artifact_prepare
ARTIFACT_DIR="$(vercel_artifact_dir)"
ISSUES_FILE="${ARTIFACT_DIR}/vercel_project_config_issues.json"
OUT_JSON="${ARTIFACT_DIR}/vercel_project_config.json"
issues_json='[]'
echo "$issues_json" >"$ISSUES_FILE"
echo '{"error":"not_run"}' >"$OUT_JSON"

TOKEN="$(vercel_token_value)"
if [[ -z "$TOKEN" ]]; then
  jq -n \
    --arg t "Vercel token missing for project \`${VERCEL_PROJECT_ID}\`" \
    --arg d "Cannot call the Vercel API without VERCEL_TOKEN or vercel_token secret." \
    --arg n "Configure vercel_token with read access to the project." \
    --argjson sev 4 \
    '[{title:$t, details:$d, severity:$sev, next_steps:$n}]' >"$ISSUES_FILE"
  echo '{"error":"missing_token"}' >"$OUT_JSON"
  exit 0
fi

# Resolve slug → prj_… id (Python). Pipe stderr to capture for issue text.
err_tmp="$(mktemp)"; resolve_tmp="$(mktemp)"
if ! vercel_py resolve-project-id --project-id "${VERCEL_PROJECT_ID}" \
        --error-out "$err_tmp" --out "$resolve_tmp" 2>>"$err_tmp"; then
  blob="$(cat "$err_tmp")"
  jq -n \
    --arg t "$(vercel_resolve_issue_title "$blob" "${VERCEL_PROJECT_ID}")" \
    --arg d "$blob" \
    --arg n "$(vercel_resolve_issue_next_steps "$blob")" \
    --argjson sev 4 \
    '[{title:$t, details:$d, severity:$sev, next_steps:$n}]' >"$ISSUES_FILE"
  echo '{"error":"resolve_failed"}' >"$OUT_JSON"
  rm -f "$err_tmp" "$resolve_tmp"
  exit 0
fi
PRJ_ID="$(jq -r '.id' "$resolve_tmp")"
rm -f "$err_tmp" "$resolve_tmp"

# Fetch the full project (Python), then sanitize fields here with jq.
err_tmp="$(mktemp)"; raw_tmp="$(mktemp)"
if ! vercel_py get-project --project-id "$PRJ_ID" \
        --error-out "$err_tmp" --out "$raw_tmp" 2>>"$err_tmp"; then
  blob="$(cat "$err_tmp")"
  jq -n \
    --arg t "Cannot fetch Vercel project \`${VERCEL_PROJECT_ID}\`" \
    --arg d "$blob" \
    --arg n "Verify VERCEL_PROJECT_ID, VERCEL_TEAM_ID (if used), and token scope." \
    --argjson sev 4 \
    '[{title:$t, details:$d, severity:$sev, next_steps:$n}]' >"$ISSUES_FILE"
  echo "{\"error\":\"get_project_failed\"}" >"$OUT_JSON"
  rm -f "$err_tmp" "$raw_tmp"
  exit 0
fi
rm -f "$err_tmp"

jq '
  {
    id, name, accountId, framework, nodeVersion, rootDirectory,
    outputDirectory, buildCommand, devCommand, installCommand,
    commandForIgnoringBuildStep, serverlessFunctionRegion, createdAt,
    directoryListing, publicSource, skipGitConnectDuringLink,
    link: (.link | if . == null then null else {
      type, repo, repoId, repoOwnerId, productionBranch, gitCredentialId,
      createdAt, updatedAt, deployHooksDisabled
    } end),
    latestDeployments: (.latestDeployments // null),
    speedInsights: (.speedInsights // null),
    analyticsId: (.analyticsId // null),
    resourceConfig: (.resourceConfig // null),
    enablePreviewFeedback: (.enablePreviewFeedback // null),
    permissions: (.permissions // null),
    environment_variable_count: ((.environmentVariables // []) | length),
    environment_variable_keys: [(.environmentVariables // [])[]?.key] | unique
  }
' "$raw_tmp" >"$OUT_JSON"
rm -f "$raw_tmp"

echo '[]' >"$ISSUES_FILE"

# Markdown report → stdout (Add Pre To Report consumes ${result.stdout}).
jq -r --arg pid "${VERCEL_PROJECT_ID}" --arg out "${OUT_JSON}" '
  def fmt_ts(ms):
    if (ms // 0) == 0 then "-"
    else ((ms | tonumber) / 1000 | strftime("%Y-%m-%dT%H:%M:%SZ")) end;
  "### Project configuration — \($pid)",
  "",
  "- **Vercel id:** `\(.id // "-")`",
  "- **Name:** \(.name // "-")",
  "- **Framework:** \(.framework // "-")",
  "- **Node version:** \(.nodeVersion // "-")",
  "- **Function region:** \(.serverlessFunctionRegion // "-")",
  "- **Root directory:** \(.rootDirectory // "-")",
  "- **Output directory:** \(.outputDirectory // "-")",
  "- **Build command:** \(.buildCommand // "(default)")",
  "- **Install command:** \(.installCommand // "(default)")",
  "- **Dev command:** \(.devCommand // "(default)")",
  "- **Ignored-build command:** \(.commandForIgnoringBuildStep // "-")",
  "- **Public source:** \(.publicSource // "-")",
  "- **Created:** \(fmt_ts(.createdAt))",
  (
    if (.link // null) == null then "- **Git link:** _not linked_"
    else
      "- **Git link:** \(.link.type // "-") `\(.link.repo // "-")`",
      "- **Production branch:** \(.link.productionBranch // "-")",
      "- **Deploy hooks disabled:** \(.link.deployHooksDisabled // false)"
    end
  ),
  "- **Speed Insights:** \(if (.speedInsights // null) == null then "_off_" else "enabled" end)",
  "- **Analytics id:** \(.analyticsId // "_unset_")",
  "- **Environment variables:** \(.environment_variable_count // 0) configured",
  (
    if ((.environment_variable_keys // []) | length) == 0 then "_no env-var keys exposed by API_"
    else "  - keys (sample, up to 20): " + ((.environment_variable_keys // [])[0:20] | join(", "))
    end
  ),
  "",
  "Artifact: `\($out)`"
' "$OUT_JSON"
