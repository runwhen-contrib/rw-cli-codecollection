#!/usr/bin/env bash
# Render a markdown snapshot of Vercel project metadata.
#
# The Robot caller (runbook.robot::Fetch Vercel Project Configuration Worker)
# resolves the slug and calls GET /v9/projects/{id} via the `Vercel` Python
# keyword library, then drops the raw response at $VERCEL_PROJECT_RAW_PATH.
# This script only sanitizes that JSON to vercel_project_config.json (used by
# downstream tasks for cache lookups such as accountId) and emits the markdown
# report on stdout.
#
# When VERCEL_API_STATUS != "ok", Robot has already opened an issue, so this
# script just emits a short status line and exits cleanly.
set -uo pipefail

: "${VERCEL_PROJECT_ID:?Must set VERCEL_PROJECT_ID}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vercel-helpers.sh
source "${SCRIPT_DIR}/vercel-helpers.sh"

vercel_artifact_prepare
ARTIFACT_DIR="$(vercel_artifact_dir)"
RAW_PATH="${VERCEL_PROJECT_RAW_PATH:-${ARTIFACT_DIR}/vercel_project_raw.json}"
OUT_JSON="${ARTIFACT_DIR}/vercel_project_config.json"
ISSUES_FILE="${ARTIFACT_DIR}/vercel_project_config_issues.json"

# Robot owns the issues for API failures; this file is preserved so the
# legacy task contract (every worker writes <task>_issues.json) is met.
echo '[]' >"$ISSUES_FILE"

if [[ "${VERCEL_API_STATUS:-ok}" != "ok" ]]; then
  echo '{"error":"'"${VERCEL_API_STATUS:-ok}"'"}' >"$OUT_JSON"
  echo "## Project configuration — \`${VERCEL_PROJECT_ID}\`"
  echo
  echo "_API call did not complete (${VERCEL_API_STATUS:-ok}); see the runbook issue panel for details._"
  exit 0
fi

if [[ ! -s "$RAW_PATH" ]]; then
  echo '{"error":"missing_input"}' >"$OUT_JSON"
  echo "## Project configuration — \`${VERCEL_PROJECT_ID}\`"
  echo
  echo "_Project JSON not found at \`${RAW_PATH}\` — Robot did not produce input._"
  exit 0
fi

# Sanitize the raw project payload (drops env-var values, keeps shape downstream
# tasks rely on: id, accountId, latestDeployments, etc.).
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
' "$RAW_PATH" >"$OUT_JSON"

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
