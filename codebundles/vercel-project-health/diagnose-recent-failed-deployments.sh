#!/usr/bin/env bash
# Enrich recent ERROR / CANCELED Vercel deployments with their actual failure
# reason. Reads the deployment-branches snapshot artifact, picks the newest
# failed deployments (capped by MAX_FAILED_DEPLOYMENTS_TO_DIAGNOSE), and pulls
# GET /v13/deployments/{id} for each. Emits a markdown report and one issue
# per surfaced failure so on-call sees the actual error message instead of
# just a count.
#
# Inputs:
#   $VERCEL_ARTIFACT_DIR/vercel_deployments_snapshot.json (from the
#     'Report Vercel Deployment Branches and Status' task)
#
# Outputs:
#   $VERCEL_ARTIFACT_DIR/vercel_failed_deployment_diagnoses.json
#   $VERCEL_ARTIFACT_DIR/vercel_failed_deployment_diagnoses_issues.json
#
# stdout: a markdown report block.
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=vercel-helpers.sh
source "${SCRIPT_DIR}/vercel-helpers.sh"

vercel_artifact_prepare
ARTIFACT_DIR="$(vercel_artifact_dir)"
SNAPSHOT_FILE="${ARTIFACT_DIR}/vercel_deployments_snapshot.json"
OUT_FILE="${ARTIFACT_DIR}/vercel_failed_deployment_diagnoses.json"
ISSUES_FILE="${ARTIFACT_DIR}/vercel_failed_deployment_diagnoses_issues.json"

MAX_TO_DIAGNOSE="${MAX_FAILED_DEPLOYMENTS_TO_DIAGNOSE:-2}"

echo '[]' >"$OUT_FILE"
echo '[]' >"$ISSUES_FILE"

echo "## Recent failed deployment diagnostics"
echo
echo "- **Cap:** \`MAX_FAILED_DEPLOYMENTS_TO_DIAGNOSE=${MAX_TO_DIAGNOSE}\` (newest failed deploys, most recent first)"
echo "- **Endpoint:** \`GET /v13/deployments/{id}\` (one call per surfaced failure)"

if [[ ! -s "$SNAPSHOT_FILE" ]]; then
  echo
  echo "_No deployments snapshot found at \`${SNAPSHOT_FILE}\`. Run the deployment-branches task first._"
  exit 0
fi

# Pick newest ERROR/CANCELED deploys from the snapshot.
FAILED_IDS_JSON="$(
  jq -c --argjson cap "$MAX_TO_DIAGNOSE" '
    ( .deployments // .latestDeployments // [] ) as $deps
    | $deps
    | map(select(
        ((.readyState // .state // .status // "") | ascii_upcase)
        | IN("ERROR","CANCELED","FAILED")
      ))
    | sort_by(- (.createdAt // 0))
    | .[0:$cap]
    | map(.uid // .id // .url // empty)
    | map(select(. != null and . != ""))
  ' "$SNAPSHOT_FILE" 2>/dev/null || echo '[]'
)"
FAILED_COUNT="$(echo "$FAILED_IDS_JSON" | jq 'length' 2>/dev/null || echo 0)"

echo "- **Failed deploys found in snapshot:** ${FAILED_COUNT}"
echo

if [[ "$FAILED_COUNT" == "0" ]]; then
  echo "_No ERROR / CANCELED deployments in the snapshot — nothing to diagnose._"
  exit 0
fi

# For each failed deployment, fetch full record and extract a useful summary.
diag_jsonl="$(mktemp)"
issues_jsonl="$(mktemp)"
: >"$diag_jsonl"
: >"$issues_jsonl"

while IFS= read -r dep_id; do
  [[ -z "$dep_id" || "$dep_id" == "null" ]] && continue
  raw_tmp="$(mktemp)"
  err_tmp="$(mktemp)"
  if vercel_py get-deployment --deployment-id "$dep_id" \
       --error-out "$err_tmp" --out "$raw_tmp" 2>>"$err_tmp"; then
    jq -c --arg dep_id "$dep_id" '
      def num(x): (x // 0 | tonumber? // 0);
      def fmt_ts(ms): if (ms // 0) <= 0 then "-" else (ms / 1000 | strftime("%Y-%m-%dT%H:%M:%SZ")) end;
      {
        deployment_id: ($dep_id),
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
    ' "$raw_tmp" >>"$diag_jsonl"
  else
    err_text="$(head -c 600 "$err_tmp" | sed 's/[[:cntrl:]]//g')"
    jq -c -n --arg dep_id "$dep_id" --arg err "$err_text" \
      '{deployment_id: $dep_id, error: $err}' >>"$diag_jsonl"
  fi
  rm -f "$raw_tmp" "$err_tmp"
done < <(echo "$FAILED_IDS_JSON" | jq -r '.[]?')

# Build the consolidated JSON output and the issues array.
jq -s '.' "$diag_jsonl" >"$OUT_FILE"

DIAG_COUNT="$(jq 'length' "$OUT_FILE" 2>/dev/null || echo 0)"

if [[ "$DIAG_COUNT" -gt 0 ]]; then
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

rm -f "$diag_jsonl" "$issues_jsonl"
