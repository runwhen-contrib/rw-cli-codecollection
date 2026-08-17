#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID  - GCP project containing Cloud Composer environments
#   ENV_NAME        - optional; pin to a single environment name, or 'All'
#
# Flags Cloud Composer environments that are not in a RUNNING state, or whose
# data-plane web server reports unhealthy (e.g. the Airflow web server cannot
# reach its metadata database). The control-plane `state` alone reports RUNNING
# even when Airflow is broken, so the web server health metric is checked too.
# Outputs a JSON array of issues to env_state_issues.json.
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${ENV_NAME:=All}"
: "${LOCATIONS:=us-central1}"

OUTPUT_FILE="env_state_issues.json"
TMP_FILE="${OUTPUT_FILE}.tmp"
> "$TMP_FILE"

echo "Checking Cloud Composer environment state for project: $GCP_PROJECT_ID"

# Query the Composer data-plane web server health metric (bool true/false).
# Unlike the control-plane `state`, this reflects whether the Airflow web
# server is actually able to serve.
get_web_server_health() {
  local env_name="$1" token query
  token=$(gcloud auth print-access-token 2>/dev/null)
  [ -z "$token" ] && { echo '[]'; return 0; }
  query="fetch cloud_composer_environment::composer.googleapis.com/environment/web_server/health | filter resource.environment_name == '${env_name}' | within 15m"
  curl -s -X POST "https://monitoring.googleapis.com/v3/projects/${GCP_PROJECT_ID}/timeSeries:query" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg q "$query" '{query: $q}')" 2>/dev/null \
    | jq -c '[.timeSeriesData[]?.pointData[]?.values[]?.boolValue // empty]'
}

envs=$(gcloud composer environments list --project="$GCP_PROJECT_ID" --locations="$LOCATIONS" --format=json 2>/dev/null || echo "[]")

if [ "$(echo "$envs" | jq 'length')" -eq 0 ]; then
  echo "No Cloud Composer environments found in project $GCP_PROJECT_ID."
  echo "[]" > "$OUTPUT_FILE"
  rm -f "$TMP_FILE"
  exit 0
fi

echo "$envs" | jq -c '.[]' | while read -r env; do
  name=$(echo "$env" | jq -r '.name')
  short_name=$(echo "$name" | awk -F'/' '{print $NF}')
  location=$(echo "$name" | awk -F'/' '{print $4}')

  if [ "$ENV_NAME" != "All" ] && [ "$ENV_NAME" != "$short_name" ]; then
    continue
  fi

  echo "Checking state for environment: $short_name (location: $location)"
  state=$(gcloud composer environments describe "$short_name" \
    --location="$location" \
    --project="$GCP_PROJECT_ID" \
    --format='value(state)' 2>/dev/null || echo "UNKNOWN")

  echo "  Control-plane state: $state"

  if [ "$state" != "RUNNING" ]; then
    jq -n --arg sn "$short_name" --arg l "$location" --arg st "$state" --arg p "$GCP_PROJECT_ID" \
      '{title: ("Cloud Composer environment `" + $sn + "` is not healthy"),
        expected: ("Cloud Composer environment `" + $sn + "` should be in a RUNNING state"),
        actual: ("Cloud Composer environment `" + $sn + "` in location `" + $l + "` is in state `" + $st + "`"),
        severity: 3,
        details: ("Cloud Composer environment `" + $sn + "` in location `" + $l + "` of project `" + $p + "` was found in state `" + $st + "`. Only the RUNNING state indicates a fully operational environment."),
        next_steps: "Investigate why the environment is not RUNNING. Check the environment createTime/updateTime for in-progress operations, review composer error logs, and verify the underlying infrastructure (GKE cluster, Cloud SQL, worker nodes) before restarting or updating the environment.",
        environment: $sn,
        state: $st,
        issue_type: "environment_not_running"}' >> "$TMP_FILE"
  else
    # Data-plane health: the control-plane `state` says RUNNING, but the web
    # server may still be crash-looping against an unreachable metadata DB.
    web_health=$(get_web_server_health "$short_name")
    unhealthy=$(echo "$web_health" | jq '[.[] | select(. == false)] | length')
    total=$(echo "$web_health" | jq 'length')
    echo "  Web server health (last 15m): ${unhealthy} unhealthy of ${total} samples"
    if [ "$total" -gt 0 ] && [ "$unhealthy" -gt 0 ]; then
      jq -n --arg sn "$short_name" --arg l "$location" --arg p "$GCP_PROJECT_ID" \
        --argjson un "$unhealthy" --argjson tot "$total" \
        '{title: ("Cloud Composer environment `" + $sn + "` web server is unhealthy"),
          expected: ("Cloud Composer environment `" + $sn + "` should report a healthy web server"),
          actual: ("Cloud Composer environment `" + $sn + "` web server reported unhealthy for " + ($un|tostring) + " of " + ($tot|tostring) + " samples in the last 15 minutes"),
          severity: 3,
          details: ("Cloud Composer environment `" + $sn + "` in location `" + $l + "` of project `" + $p + "` reported " + ($un|tostring) + " unhealthy web server sample(s) out of " + ($tot|tostring) + " in the last 15 minutes. This usually means the Airflow web server cannot reach its metadata database, leaving the environment partially or fully unavailable."),
          next_steps: "Check Cloud Logging for sqlalchemy/database connection errors, verify the environment metadata database is reachable, and if it persists recreate or repair the environment.",
          environment: $sn,
          unhealthy_samples: $un,
          total_samples: $tot,
          issue_type: "web_server_unhealthy"}' >> "$TMP_FILE"
    fi
  fi
done

if [ -s "$TMP_FILE" ]; then
  jq -s '.' "$TMP_FILE" > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi
rm -f "$TMP_FILE"

echo "Environment state check complete. $(jq length "$OUTPUT_FILE") issue(s) found."
