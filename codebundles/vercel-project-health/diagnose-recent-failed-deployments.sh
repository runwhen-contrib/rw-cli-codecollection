#!/usr/bin/env bash
# Render diagnostics for recent ERROR / CANCELED Vercel deployments.
#
# The Robot caller (runbook.robot::Diagnose Recent Failed Vercel Deployments
# Worker) reads $VERCEL_ARTIFACT_DIR/vercel_deployments_snapshot.json (produced
# by the deployment-branches task), picks the newest failed deployments
# (capped by MAX_FAILED_DEPLOYMENTS_TO_DIAGNOSE), calls GET /v13/deployments/
# {id} for each via the `Vercel` Python keyword library, and drops the array
# of full records (each tagged with `_lookup_id`) at
# $VERCEL_FAILED_DEPLOYMENT_RECORDS_PATH. This script:
#
#   - normalizes that array to a per-deployment summary at
#     vercel_failed_deployment_diagnoses.json,
#   - emits one issue per surfaced failure (real errorCode/errorMessage),
#   - emits a markdown report.
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=vercel-helpers.sh
source "${SCRIPT_DIR}/vercel-helpers.sh"

vercel_artifact_prepare
ARTIFACT_DIR="$(vercel_artifact_dir)"
RECORDS_FILE="${VERCEL_FAILED_DEPLOYMENT_RECORDS_PATH:-${ARTIFACT_DIR}/vercel_failed_deployment_records.json}"
OUT_FILE="${ARTIFACT_DIR}/vercel_failed_deployment_diagnoses.json"
ISSUES_FILE="${ARTIFACT_DIR}/vercel_failed_deployment_diagnoses_issues.json"

MAX_TO_DIAGNOSE="${MAX_FAILED_DEPLOYMENTS_TO_DIAGNOSE:-2}"

echo '[]' >"$OUT_FILE"
echo '[]' >"$ISSUES_FILE"

echo "## Recent failed deployment diagnostics"
echo
echo "- **Cap:** \`MAX_FAILED_DEPLOYMENTS_TO_DIAGNOSE=${MAX_TO_DIAGNOSE}\` (newest failed deploys, most recent first)"
echo "- **Endpoint:** \`GET /v13/deployments/{id}\` (one call per surfaced failure)"

case "${VERCEL_API_STATUS:-ok}" in
  ok)        : ;;
  missing-token)
    echo
    echo "_Vercel token missing — see runbook issue panel for details._"
    exit 0
    ;;
  missing-snapshot)
    echo
    echo "_No deployments snapshot found at \`${VERCEL_FAILED_DEPLOYMENT_SNAPSHOT_PATH:-${ARTIFACT_DIR}/vercel_deployments_snapshot.json}\`. Run the deployment-branches task first._"
    exit 0
    ;;
  *)
    echo
    echo "_API call did not complete (${VERCEL_API_STATUS}); see the runbook issue panel for details._"
    exit 0
    ;;
esac

if [[ ! -s "$RECORDS_FILE" ]]; then
  echo '[]' >"$RECORDS_FILE"
fi

DIAG_COUNT="${VERCEL_FAILED_DEPLOYMENT_COUNT:-$(jq 'length' "$RECORDS_FILE" 2>/dev/null || echo 0)}"
DIAG_COUNT="${DIAG_COUNT:-0}"
echo "- **Failed deploys diagnosed:** ${DIAG_COUNT}"
echo

if [[ "$DIAG_COUNT" == "0" ]]; then
  echo "_No ERROR / CANCELED deployments in the snapshot — nothing to diagnose._"
  exit 0
fi

# Normalize each Robot-fetched deployment record to the per-deployment summary.
jq -c '
  def num(x): (x // 0 | tonumber? // 0);
  def fmt_ts(ms): if (ms // 0) <= 0 then "-" else (ms / 1000 | strftime("%Y-%m-%dT%H:%M:%SZ")) end;
  map(
    if (.error // null) != null then
      {
        deployment_id: (._lookup_id // .uid // .id // null),
        error: (.error | tostring | .[0:600])
      }
    else
      {
        deployment_id: (._lookup_id // .uid // .id // null),
        url: (.url // null),
        target: (.target // null),
        state: (.readyState // .state // .status // null),
        created_at: fmt_ts(.createdAt // null),
        building_at: fmt_ts(.buildingAt // null),
        ready_at: fmt_ts(.ready // null),
        build_duration_seconds: (
          if (num(.ready) > 0 and num(.buildingAt) > 0) then
            ((num(.ready) - num(.buildingAt)) / 1000 | floor)
          else null end
        ),
        error_code: (.errorCode // null),
        error_message: (.errorMessage // null),
        error_step: (.errorStep // null),
        alias_error: (.aliasError // null),
        git_branch: (.meta.githubCommitRef // .gitSource.ref // null),
        git_commit_sha: (.meta.githubCommitSha // .gitSource.sha // null),
        git_commit_message: (.meta.githubCommitMessage // null),
        creator: (.creator.username // .creator.email // null),
        regions: (.regions // [])
      }
    end
  )
' "$RECORDS_FILE" >"$OUT_FILE"

OUT_COUNT="$(jq 'length' "$OUT_FILE" 2>/dev/null || echo 0)"
if [[ "$OUT_COUNT" -gt 0 ]]; then
  echo "### Failed deployment details"
  echo
  echo "| Deployment | State | Branch | Commit | Build duration | Error code | Error message |"
  echo "| --- | --- | --- | --- | ---: | --- | --- |"
  jq -r '
    .[]
    | "| `\(.deployment_id)`" +
      " | \(.state // "-")" +
      " | \(.git_branch // "-")" +
      " | \((.git_commit_sha // "-") | .[0:8])" +
      " | \(if .build_duration_seconds == null then "-" else "\(.build_duration_seconds)s" end)" +
      " | \(.error_code // "-")" +
      " | \((.error_message // .error // "-") | gsub("[\\n\\r|]"; " ") | .[0:120])" +
      " |"
  ' "$OUT_FILE"
  echo

  # One issue per failed deployment with a real error reason.
  jq -c '
    map(select(.error_message != null or .error_code != null or .alias_error != null or .error != null))
    | map({
        severity: 3,
        title: ("Vercel deployment `" + .deployment_id + "` failed: " +
                ((.error_code // "ERROR") + " — " +
                 ((.error_message // .alias_error // .error // "no message") | gsub("[\\n\\r]"; " ") | .[0:100]))),
        details: (
          "State: " + (.state // "ERROR") + "\n" +
          "Created: " + (.created_at // "-") + "\n" +
          "Branch: " + (.git_branch // "-") + " @ " + ((.git_commit_sha // "-") | .[0:8]) + "\n" +
          "Commit: " + (.git_commit_message // "-") + "\n" +
          (if .build_duration_seconds != null then "Build duration: " + (.build_duration_seconds | tostring) + "s\n" else "" end) +
          "Error code: " + (.error_code // "-") + "\n" +
          "Error message: " + (.error_message // "-") + "\n" +
          (if .alias_error != null then "Alias error: " + (.alias_error | tostring) + "\n" else "" end)
        ),
        next_steps: (
          "Open https://vercel.com/_dashboard/deployments/" + .deployment_id +
          " and review the build log for the full traceback. If the error is dependency-related, run the build locally with the same Node version (" +
          "see project config) to reproduce. If the error is a Vercel platform error (errorCode starts with `BUILD_` and errorMessage references infrastructure), retry the deployment from the dashboard."
        )
      })
  ' "$OUT_FILE" >"$ISSUES_FILE"
else
  echo "_get-deployment calls returned no usable rows; see ${OUT_FILE} for raw output._"
fi
