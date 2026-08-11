#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Cloud Run service request concurrency and instance scaling settings.
#
# Reviews the scaling configuration of each Cloud Run service and flags:
#   - Unbounded max instances (autoscaling.knative.dev/maxScale unset or "0"),
#     a cost risk from unlimited scaling (severity 3)
#   - Very low concurrency targets (containerConcurrency set below 10), which
#     under-utilize each instance and inflate cost (severity 2)
#   - Min-instances settings above 0, which keep (possibly cold/idle) instances
#     warm and billed (severity 2)
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID - GCP project ID
#   RESOURCES      - Comma-separated service names, or "All" (default)
#
# OUTPUTS:
#   concurrency_scaling_issues.json - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${RESOURCES:=All}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISSUES_FILE="concurrency_scaling_issues.json"
issues_json='[]'

# Constant: lowest "sane" concurrency target (default Cloud Run value is 80).
CONCURRENCY_MIN=10

echo "Checking Cloud Run service concurrency and scaling settings for project: $GCP_PROJECT_ID (min concurrency considered sane: ${CONCURRENCY_MIN})"

source "$SCRIPT_DIR/discover_services.sh"

jq -c '.[]' "$DISCOVERY_FILE" | while read -r svc; do
  name=$(echo "$svc" | jq -r '.name')
  region=$(echo "$svc" | jq -r '.region')
  max_scale=$(echo "$svc" | jq -r '.maxScale')
  min_scale=$(echo "$svc" | jq -r '.minScale')
  concurrency=$(echo "$svc" | jq -r '.containerConcurrency')

  echo "  Service '$name' ($region): maxScale='$max_scale' minScale='$min_scale' concurrency='$concurrency'"

  # --- Unbounded max instances ---
  if [ -z "$max_scale" ] || [ "$max_scale" = "0" ]; then
    issue=$(jq -n \
        --arg title "Cloud Run service \`$name\` has unbounded maximum instances" \
        --arg details "Cloud Run service '$name' in region '$region' of project '$GCP_PROJECT_ID' does not set a maximum instance cap (autoscaling.knative.dev/maxScale unset or 0). A traffic spike or retry storm can drive the instance count -- and the bill -- without bound." \
        --arg severity "3" \
        --arg expected "Cloud Run services should have a bounded maximum instance count" \
        --arg actual "No maximum instance cap configured for '$name'" \
        --arg next_steps "Set a max instances limit on '$name': gcloud run services update $name --region=$region --max-instances=<n> --project=$GCP_PROJECT_ID." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
    echo "$issues_json" > "$ISSUES_FILE"
  fi

  # --- Very low concurrency target ---
  if [ -n "$concurrency" ] && [ "$concurrency" != "0" ] 2>/dev/null && [ "$concurrency" -lt "$CONCURRENCY_MIN" ] 2>/dev/null; then
    issue=$(jq -n \
        --arg title "Cloud Run service \`$name\` has a very low concurrency target" \
        --arg details "Cloud Run service '$name' in region '$region' of project '$GCP_PROJECT_ID' is configured with a container concurrency target of ${concurrency}. Very low concurrency means each instance handles very few simultaneous requests, under-utilizing capacity and increasing cost per request." \
        --arg severity "2" \
        --arg expected "Cloud Run concurrency targets should be reasonable (>= ${CONCURRENCY_MIN})" \
        --arg actual "Cloud Run service '$name' has concurrency target ${concurrency}" \
        --arg next_steps "Increase the concurrency target for '$name' if the workload supports concurrent requests: gcloud run services update $name --region=$region --concurrency=<n> --project=$GCP_PROJECT_ID. Validate the container handles concurrent requests safely." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
    echo "$issues_json" > "$ISSUES_FILE"
  fi

  # --- Min instances above 0 (keeps instances warm) ---
  if [ -n "$min_scale" ] && [ "$min_scale" != "0" ] 2>/dev/null; then
    issue=$(jq -n \
        --arg title "Cloud Run service \`$name\` keeps minimum instances warm" \
        --arg details "Cloud Run service '$name' in region '$region' of project '$GCP_PROJECT_ID' is configured with a minimum instance count of ${min_scale} (autoscaling.knative.dev/minScale). Minimum instances keep instances warm and billable even when idle, which can waste capacity for low-traffic services." \
        --arg severity "2" \
        --arg expected "Minimum instance counts should be 0 unless cold-start latency requires warm instances" \
        --arg actual "Cloud Run service '$name' has min instances = ${min_scale}" \
        --arg next_steps "If '$name' tolerates cold starts, set min instances to 0: gcloud run services update $name --region=$region --min-instances=0 --project=$GCP_PROJECT_ID. Otherwise confirm the warm instances are justified by the latency requirements." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
    echo "$issues_json" > "$ISSUES_FILE"
  fi
done

if [ ! -s "$ISSUES_FILE" ]; then
    echo "[]" > "$ISSUES_FILE"
fi

echo "Concurrency/scaling check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
