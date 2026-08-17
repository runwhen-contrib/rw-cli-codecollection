#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee Security Score and Incidents
#
# Queries Cloud Monitoring for Apigee security metrics in GCP_PROJECT_ID and
# raises ONE finding PER FAILURE MODE:
#
#   1. Security score below SECURITY_SCORE_THRESHOLD
#   2. Detected security requests over the window
#   3. Incident-associated requests over the window
#
# Titles carry the failure mode and the org, never the score or a request count:
# those change on every collection, so a title carrying one opens and closes an
# issue every run. The numbers live in details/actual.
#
# ABSENCE IS NOT UNHEALTHY. Apigee security metrics
# (apigee.googleapis.com/security/*) only populate when Advanced API Security is
# enabled. No data means "not measured here", which is a positive determination
# of absence and raises nothing -- it is NOT a score of zero.
#
# REQUIRED ENV VARS:
#   APIGEE_ORG                    - Apigee organization name
#   GCP_PROJECT_ID                - GCP project ID hosting the Apigee runtime
#
# OPTIONAL ENV VARS:
#   SECURITY_SCORE_THRESHOLD      - Minimum acceptable score (default 80)
#   SECURITY_WINDOW_HOURS         - Lookback window in hours (default 6)
#
# AUTH:
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
: "${SECURITY_WINDOW_HOURS:=6}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/apigee_common.sh"

OUTPUT_FILE="security_score_issues.json"
MONITORING="https://monitoring.googleapis.com/v3/projects/${GCP_PROJECT_ID}"
issues_json='[]'

APIGEE_ORG="${APIGEE_ORG#organizations/}"

echo "Checking Apigee security score/incidents for org: ${APIGEE_ORG} (project ${GCP_PROJECT_ID}, threshold ${SECURITY_SCORE_THRESHOLD})"

TOKEN="$(apigee_token)"
if [ -z "${TOKEN}" ]; then
    # Failure to determine, not a determination of absence.
    jq -n \
        --arg title "Cannot read Apigee security metrics in org \`${APIGEE_ORG}\`" \
        --arg details "Unable to obtain a GCP access token for the Cloud Monitoring API in project ${GCP_PROJECT_ID}. No security metric was read, so this run determined nothing about the org's security posture." \
        --arg severity "3" \
        --arg expected "Cloud Monitoring access should be authenticated." \
        --arg actual "Could not obtain an access token, so no security metric was read." \
        --arg next_steps "Verify the service account is authenticated and has roles/monitoring.viewer." \
        '[{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}]' \
        > "${OUTPUT_FILE}"
    exit 0
fi

# GNU date takes -d '<n> hours ago'; BSD/macOS date takes -v-<n>H. The runner is
# Linux, but a script that aborts under `set -e` before it queries anything is
# untestable on a developer's machine.
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
start_iso="$(date -u -d "${SECURITY_WINDOW_HOURS} hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-"${SECURITY_WINDOW_HOURS}"H +%Y-%m-%dT%H:%M:%SZ)"

query() {
    # query <metric-type> <aligner> <reducer-args-json>
    curl -s -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
        -X POST "${MONITORING}/timeSeries:list" -d "{
          \"filter\":\"metric.type=\\\"$1\\\"\",
          \"interval\":{\"startTime\":\"${start_iso}\",\"endTime\":\"${now_iso}\"},
          \"aggregation\":$2
        }" 2>/dev/null || echo '{}'
}

latest_value() {
    query "$1" '{"alignmentPeriod":"300s","perSeriesAligner":"ALIGN_MEAN"}' | jq -r '
        [.timeSeries[]?.points[]?.value | (.doubleValue // .int64Value // empty)]
        | map(select(. != null)) | if length == 0 then "" else (.[0] | tostring) end' 2>/dev/null || echo ""
}

sum_value() {
    query "$1" '{"alignmentPeriod":"60s","perSeriesAligner":"ALIGN_SUM","crossSeriesReducer":"REDUCE_SUM"}' | jq -r '
        [.timeSeries[]?.points[]?.value | (.doubleValue // .int64Value // empty)]
        | map(select(. != null) | tonumber) | if length == 0 then "" else (add | tostring) end' 2>/dev/null || echo ""
}

echo "  Querying security/score..."
score="$(latest_value "apigee.googleapis.com/security/score")"
if [ -n "${score}" ]; then
    echo "  Security score: ${score}"
    # awk rather than python3: the runner image is not guaranteed to carry a
    # python3, and a failed conversion here previously fell through to a string
    # comparison that could not fire.
    below="$(awk -v s="${score}" -v t="${SECURITY_SCORE_THRESHOLD}" 'BEGIN { print (s + 0 < t + 0) ? "1" : "0" }')"
    critical="$(awk -v s="${score}" 'BEGIN { print (s + 0 < 40) ? "1" : "0" }')"
    if [ "${below}" = "1" ]; then
        sev=3
        [ "${critical}" = "1" ] && sev=4
        issue=$(jq -n \
            --arg title "Apigee security score is below the acceptable threshold in org \`${APIGEE_ORG}\`" \
            --arg details "The Apigee security score for org ${APIGEE_ORG} (project ${GCP_PROJECT_ID}) is ${score}, below the acceptable threshold of ${SECURITY_SCORE_THRESHOLD}. A low score means Advanced API Security has unresolved risks recorded against the gateway." \
            --arg severity "${sev}" \
            --arg expected "The Apigee security score should be at or above ${SECURITY_SCORE_THRESHOLD}." \
            --arg actual "Security score is ${score}, threshold ${SECURITY_SCORE_THRESHOLD}." \
            --arg next_steps "Review the Apigee security recommendations in Advanced API Security and remediate the highest-severity findings to raise the score." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
    fi
else
    # Not measured is not unhealthy.
    echo "  No security/score data returned (Advanced API Security may not be enabled); raising nothing."
fi

echo "  Querying security/detected_request_count..."
detected="$(sum_value "apigee.googleapis.com/security/detected_request_count")"
if [ -n "${detected}" ] && [ "$(awk -v d="${detected}" 'BEGIN { print (d + 0 > 0) ? "1" : "0" }')" = "1" ]; then
    echo "  Detected requests: ${detected}"
    issue=$(jq -n \
        --arg title "Apigee detected abusive traffic reaching the gateway in org \`${APIGEE_ORG}\`" \
        --arg details "Cloud Monitoring reports ${detected} detected security request(s) for org ${APIGEE_ORG} (project ${GCP_PROJECT_ID}) in the last ${SECURITY_WINDOW_HOURS} hours. Advanced API Security classifies these as abuse or attack attempts that reached the gateway." \
        --arg severity "3" \
        --arg expected "No traffic should be classified as a detected security request." \
        --arg actual "${detected} detected security request(s) in the last ${SECURITY_WINDOW_HOURS} hours." \
        --arg next_steps "Investigate the detected requests in Apigee Advanced API Security and tighten the security profiles and anomaly detection rules that classified them." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
else
    echo "  No detected requests, or the metric is not populated; raising nothing."
fi

echo "  Querying security/incident_request_count..."
incidents="$(sum_value "apigee.googleapis.com/security/incident_request_count")"
if [ -n "${incidents}" ] && [ "$(awk -v d="${incidents}" 'BEGIN { print (d + 0 > 0) ? "1" : "0" }')" = "1" ]; then
    echo "  Incident requests: ${incidents}"
    issue=$(jq -n \
        --arg title "Apigee has open security incidents in org \`${APIGEE_ORG}\`" \
        --arg details "Cloud Monitoring reports ${incidents} incident-associated request(s) for org ${APIGEE_ORG} (project ${GCP_PROJECT_ID}) in the last ${SECURITY_WINDOW_HOURS} hours. Advanced API Security groups these into an incident, which means a pattern was identified rather than isolated requests." \
        --arg severity "3" \
        --arg expected "No active security incidents should be recorded against the organization." \
        --arg actual "${incidents} incident-associated request(s) in the last ${SECURITY_WINDOW_HOURS} hours." \
        --arg next_steps "Triage the open incidents in Apigee Advanced API Security and apply the recommended mitigations." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
else
    echo "  No incident requests, or the metric is not populated; raising nothing."
fi

echo "${issues_json}" > "${OUTPUT_FILE}"
echo "Security score check complete. Found $(jq length "${OUTPUT_FILE}") issue(s)."
