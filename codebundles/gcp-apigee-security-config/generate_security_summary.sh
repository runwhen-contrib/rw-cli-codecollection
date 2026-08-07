#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Generate Apigee Security Summary
#
# Aggregates keystore/TLS, quota, app access, security score, and target/vhost
# findings into a consolidated JSON security summary for the organization.
#
# REQUIRED ENV VARS:
#   APIGEE_ORG                    - Apigee organization name
#   GCP_PROJECT_ID                - GCP project ID hosting the Apigee runtime
#
# OUTPUTS:
#   security_summary.json - consolidated security summary object
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${APIGEE_ORG:?Must set APIGEE_ORG}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="security_summary.json"

count_issues()
{
  local file="$1"
  if [ -s "$file" ]; then
    jq 'if type=="array" then length else 0 end' "$file" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

cert_count=$(count_issues "keystore_tls_issues.json")
quota_count=$(count_issues "quota_limits_issues.json")
app_count=$(count_issues "app_access_issues.json")
score_count=$(count_issues "security_score_issues.json")
target_count=$(count_issues "target_vhost_issues.json")

total_issues=$((cert_count + quota_count + app_count + score_count + target_count))

if [ "$total_issues" -eq 0 ]; then
  verdict="OK"
elif [ "$total_issues" -le 3 ]; then
  verdict="WARNING"
else
  verdict="CRITICAL"
fi

echo "Security summary for org $APIGEE_ORG: total_issues=$total_issues verdict=$verdict"

jq -n \
  --arg apigee_org "$APIGEE_ORG" \
  --arg gcp_project_id "$GCP_PROJECT_ID" \
  --argjson expiring_or_expired_certs "$cert_count" \
  --argjson weak_or_missing_quotas "$quota_count" \
  --argjson at_risk_apps "$app_count" \
  --argjson security_issues "$score_count" \
  --argjson target_vhost_issues "$target_count" \
  --argjson total_issues "$total_issues" \
  --arg verdict "$verdict" \
  '{
    "apigee_org": $apigee_org,
    "gcp_project_id": $gcp_project_id,
    "expiring_or_expired_certs": $expiring_or_expired_certs,
    "weak_or_missing_quotas": $weak_or_missing_quotas,
    "at_risk_apps": $at_risk_apps,
    "security_issues": $security_issues,
    "target_vhost_issues": $target_vhost_issues,
    "total_issues": $total_issues,
    "verdict": $verdict
  }' > "$OUTPUT_FILE"

echo "Summary generated."
jq . "$OUTPUT_FILE"
