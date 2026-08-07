#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee Keystore and TLS Alias Expiry
#
# For each environment in the Apigee organization, enumerates keystores and
# certificate aliases and flags any alias whose certificate is expired or will
# expire within CERT_EXPIRY_WARNING_DAYS days.
#
# REQUIRED ENV VARS:
#   APIGEE_ORG                    - Apigee organization name
#   GCP_PROJECT_ID                - GCP project ID hosting the Apigee runtime
#   CERT_EXPIRY_WARNING_DAYS      - Days before expiry to flag (default 30)
#
# AUTH:
#   gcloud must be authenticated (Suite Setup runs
#   `gcloud auth activate-service-account`). A bearer token is obtained via
#   `gcloud auth print-access-token`.
#
# OUTPUTS:
#   keystore_tls_issues.json - JSON array of issue objects
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${APIGEE_ORG:?Must set APIGEE_ORG}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${CERT_EXPIRY_WARNING_DAYS:=30}"

OUTPUT_FILE="keystore_tls_issues.json"
API="https://apigee.googleapis.com/v1"

echo "Checking keystore/TLS alias expiry for org: $APIGEE_ORG (warning: ${CERT_EXPIRY_WARNING_DAYS} days)"

TOKEN=$(gcloud auth print-access-token 2>/dev/null || gcloud auth application-default print-access-token 2>/dev/null || echo "")
if [ -z "$TOKEN" ]; then
  echo "Error: unable to obtain an access token. Verify gcloud authentication." >&2
  printf '[{"title":"Cannot access Apigee TLS/keystore data","details":"Unable to obtain a GCP access token for org `%s`.","severity":4,"expected":"Apigee API access should be authenticated","actual":"No access token available","next_steps":"Verify the service account is authenticated and has roles/apigee.readOnlyAdmin."}]\n' "$APIGEE_ORG" > "$OUTPUT_FILE"
  exit 0
fi

now_epoch=$(date +%s)

fetch_json_list()
{
  # $1 = full URL. Prints a compact JSON array of elements, extracting the
  # array whether the API returns a bare array or an object with a list field.
  local url="$1"
  local raw
  raw=$(curl -s -H "Authorization: Bearer $TOKEN" "$url")
  printf '%s' "$raw" | jq -c '
    if type == "array" then .
    elif (.environment != null) then .environment
    elif (.keystores != null) then .keystores
    elif (.aliases != null) then .aliases
    elif (.targetservers != null) then .targetservers
    else []
    end' 2>/dev/null || echo "[]"
}

environments=$(fetch_json_list "$API/organizations/$APIGEE_ORG/environments")
if [ "$(printf '%s' "$environments" | jq 'if type=="array" then .|length else 0 end' 2>/dev/null)" -eq 0 ]; then
  echo "No environments found for org $APIGEE_ORG."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

> "$OUTPUT_FILE"

printf '%s' "$environments" | jq -c '.[]' 2>/dev/null | while read -r env_name; do
  echo "  Checking environment: $env_name"
  keystores=$(fetch_json_list "$API/organizations/$APIGEE_ORG/environments/$env_name/keystores")
  printf '%s' "$keystores" | jq -c '.[]' 2>/dev/null | while read -r ks_obj; do
    ks_name=$(printf '%s' "$ks_obj" | jq -r '.name // empty')
    [ -z "$ks_name" ] && continue
    aliases=$(fetch_json_list "$API/organizations/$APIGEE_ORG/environments/$env_name/keystores/$ks_name/aliases")
    alias_count=$(printf '%s' "$aliases" | jq 'if type=="array" then length else 0 end' 2>/dev/null)
    if [ "$alias_count" -eq 0 ]; then
      echo "    No aliases in keystore $ks_name."
      continue
    fi
    printf '%s' "$aliases" | jq -c '.[]' 2>/dev/null | while read -r alias_obj; do
      alias_name=$(printf '%s' "$alias_obj" | jq -r '.alias // .name // empty')
      [ -z "$alias_name" ] && continue
      full_alias=$(curl -s -H "Authorization: Bearer $TOKEN" "$API/organizations/$APIGEE_ORG/environments/$env_name/keystores/$ks_name/aliases/$alias_name")
      expiry_ms=$(printf '%s' "$full_alias" | jq -r '.certsInfo.certInfo[0].expiryDate // empty' 2>/dev/null)
      if [ -z "$expiry_ms" ] || [ "$expiry_ms" = "null" ]; then
        echo "    Alias $alias_name has no certInfo expiryDate. Skipping."
        continue
      fi
      expiry_epoch=$((expiry_ms / 1000))
      days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
      echo "    Alias $alias_name (keystore $ks_name) expires in ${days_left} days"

      if [ "$days_left" -le "$CERT_EXPIRY_WARNING_DAYS" ]; then
        severity="3"
        if [ "$days_left" -lt 0 ]; then
          severity="4"
        fi
        jq -n \
          --arg title "Apigee TLS alias \`$alias_name\` (keystore \`$ks_name\`, env \`$env_name\`) expires in ${days_left} days" \
          --arg details "Alias '$alias_name' in keystore '$ks_name' in environment '$env_name' of org '$APIGEE_ORG' has a certificate that expires in ${days_left} day(s) (expiry ms: $expiry_ms). Connections using this TLS material will fail once it expires." \
          --arg severity "$severity" \
          --arg expected "All keystore aliases should be valid for more than $CERT_EXPIRY_WARNING_DAYS days" \
          --arg actual "Alias expires in $days_left days (threshold: $CERT_EXPIRY_WARNING_DAYS days)" \
          --arg next_steps "Rotate or re-upload a new certificate for alias '$alias_name' in keystore '$ks_name' before expiry via the Apigee keystore/alias management flow." \
          --arg env "$env_name" --arg keystore "$ks_name" --arg alias "$alias_name" \
          '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps,env:$env,keystore:$keystore,alias:$alias,issue_type:"tls_alias_expiry"}' >> "$OUTPUT_FILE"
      fi
    done
  done
done

if [ -s "$OUTPUT_FILE" ]; then
  jq -s '.' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "Keystore/TLS check complete. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
