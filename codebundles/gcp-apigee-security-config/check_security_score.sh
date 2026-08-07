#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee Security Score and Incidents
#
# Queries Cloud Monitoring for Apigee security metrics in GCP_PROJECT_ID and
# flags a low security score or a high number of detected security incidents.
#
# REQUIRED ENV VARS:
#   APIGEE_ORG                    - Apigee organization name
#   GCP_PROJECT_ID                - GCP project ID hosting the Apigee runtime
#   SECURITY_SCORE_THRESHOLD      - Minimum acceptable Apigee security score (default 80)
#
# NOTES:
#   Apigee security metrics (apigee.googleapis.com/security/*) only populate
#   when Advanced API Security is enabled. If no data is returned, no issue is
#   raised (the org may not have the feature enabled or have no measurements).
#
# AUTH:
#   gcloud must be authenticated; token obtained via `gcloud auth print-access-token`.
#   Requires roles/monitoring.viewer on the service account.
#
# OUTPUTS:
#   security_score_issues.json - JSON array of issue objects
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${APIGEE_ORG:?Must set APIGEE_ORG}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${SECURITY_SCORE_THRESHOLD:=80}"

OUTPUT_FILE="security_score_issues.json"
MONITORING="https://monitoring.googleapis.com/v3/projects/$GCP_PROJECT_ID"

echo "Checking Apigee security score/incidents for project: $GCP_PROJECT_ID (threshold: $SECURITY_SCORE_THRESHOLD)"

TOKEN=$(gcloud auth print-access-token 2>/dev/null || gcloud auth application-default print-access-token 2>/dev/null || echo "")
if [ -z "$TOKEN" ]; then
  echo "Error: unable to obtain an access token." >&2
  printf '[{"title":"Cannot access Apigee security metrics","details":"Unable to obtain a GCP access token for project `%s`.","severity":3,"expected":"Cloud Monitoring access should be authenticated","actual":"No access token available","next_steps":"Verify the service account is authenticated and has roles/monitoring.viewer."}]\n' "$GCP_PROJECT_ID" > "$OUTPUT_FILE"
  exit 0
fi

now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_iso=$(date -u -d '6 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-6H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)

latest_value()
{
  # $1 = metric type. Prints the latest numeric point value, or empty if none.
  local metric_type="$1"
  local resp
  resp=$(curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -X POST "$MONITORING/timeSeries:list" -d "{
      \"filter\":\"metric.type=\\\"$metric_type\\\"\",
      \"interval\":{\"startTime\":\"$start_iso\",\"endTime\":\"$now_iso\"},
      \"aggregation\":{\"alignmentPeriod\":\"300s\",\"perSeriesAligner\":\"ALIGN_MEAN\"}
    }")
  printf '%s' "$resp" | jq -r '
    [.timeSeries[]?.points[]?.value |
      (.doubleValue // .int64Value // .stringValue // empty)]
    | map(select(. != null)) | if length == 0 then "" else reverse[0] end' 2>/dev/null
}

sum_value()
{
  # $1 = metric type. Prints the sum over the window, or empty if none.
  local metric_type="$1"
  local resp
  resp=$(curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -X POST "$MONITORING/timeSeries:list" -d "{
      \"filter\":\"metric.type=\\\"$metric_type\\\"\",
      \"interval\":{\"startTime\":\"$start_iso\",\"endTime\":\"$now_iso\"},
      \"aggregation\":{\"alignmentPeriod\":\"60s\",\"perSeriesAligner\":\"ALIGN_SUM\",\"crossSeriesReducer\":\"REDUCE_SUM\"}
    }")
  printf '%s' "$resp" | jq -r '
    [.timeSeries[]?.points[]?.value |
      (.doubleValue // .int64Value // empty)]
    | map(select(. != null) | tonumber) | if length == 0 then "" else (add|tostring) end' 2>/dev/null
}

> "$OUTPUT_FILE"

echo "  Querying security/score..."
score=$(latest_value "apigee.googleapis.com/security/score")
if [ -n "$score" ]; then
  echo "  Security score: $score"
  score_int=$(python3 -c "print(int(float('$score')))" 2>/dev/null || echo "$score")
  if [ "$score_int" -lt "$SECURITY_SCORE_THRESHOLD" ]; then
    severity="3"
    if [ "$score_int" -lt 40 ]; then
      severity="4"
    fi
    jq -n \
      --arg title "Apigee security score $score (below threshold $SECURITY_SCORE_THRESHOLD) for org \`$APIGEE_ORG\`" \
      --arg details "Apigee security score for org '$APIGEE_ORG' (project '$GCP_PROJECT_ID') is $score, below the acceptable threshold of $SECURITY_SCORE_THRESHOLD. A low score indicates unresolved security risks in the API gateway." \
      --arg severity "$severity" \
      --arg expected "Apigee security score should be at or above $SECURITY_SCORE_THRESHOLD" \
      --arg actual "Security score is $score" \
      --arg next_steps "Review the Apigee security recommendations in the Apigee UI / Advanced API Security, and remediate the highest-severity findings to raise the security score." \
      '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps,issue_type:"low_security_score"}' >> "$OUTPUT_FILE"
  fi
else
  echo "  No security/score data returned (Advanced API Security may be disabled)."
fi

echo "  Querying security/detected_request_count..."
detected=$(sum_value "apigee.googleapis.com/security/detected_request_count")
if [ -n "$detected" ] && [ "$detected" -gt 0 ] 2>/dev/null; then
  echo "  Detected requests: $detected"
  jq -n \
    --arg title "Apigee detected security incidents for org \`$APIGEE_ORG\`" \
    --arg details "Cloud Monitoring reports $detected detected security requests for org '$APIGEE_ORG' (project '$GCP_PROJECT_ID') in the last 6 hours. This indicates ongoing abuse or attack attempts reaching the gateway." \
    --arg severity "3" \
    --arg expected "No security incidents should be detected; traffic should be normal" \
    --arg actual "$detected detected security requests in the last 6 hours" \
    --arg next_steps "Investigate the detected requests in Apigee Advanced API Security and adjust security profiles / anomaly detection rules." \
    '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps,issue_type:"detected_incidents"}' >> "$OUTPUT_FILE"
else
  echo "  No detected requests, or data unavailable."
fi

echo "  Querying security/incident_request_count..."
incidents=$(sum_value "apigee.googleapis.com/security/incident_request_count")
if [ -n "$incidents" ] && [ "$incidents" -gt 0 ] 2>/dev/null; then
  echo "  Incident requests: $incidents"
  jq -n \
    --arg title "Apigee security incidents recorded for org \`$APIGEE_ORG\`" \
    --arg details "Cloud Monitoring reports $incidents incident-associated requests for org '$APIGEE_ORG' (project '$GCP_PROJECT_ID') in the last 6 hours. Active incidents may indicate a security event." \
    --arg severity "3" \
    --arg expected "No active security incidents should be present" \
    --arg actual "$incidents incident request(s) in the last 6 hours" \
    --arg next_steps "Triage the open incidents in Apigee Advanced API Security and apply mitigations." \
    '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps,issue_type:"security_incidents"}' >> "$OUTPUT_FILE"
else
  echo "  No incident requests, or data unavailable."
fi

if [ -s "$OUTPUT_FILE" ]; then
  jq -s '.' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "Security score check complete. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
