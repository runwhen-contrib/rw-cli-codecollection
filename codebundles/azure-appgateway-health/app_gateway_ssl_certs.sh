#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# ENV VARS REQUIRED:
#   APP_GATEWAY_NAME  (The name of your Application Gateway)
#   AZ_RESOURCE_GROUP (The Resource Group containing the App Gateway)
#
# OPTIONAL:
#   DAYS_THRESHOLD (Integer) - how many days before expiry to warn. Default=30
#   OUTPUT_DIR     - where to store the resulting JSON, default=./output
#
# This script:
#   1) Retrieves the Application Gateway JSON
#   2) Iterates over all sslCertificates[] in its config
#   3) Checks the "expiry" field to see how many days remain
#   4) Logs an issue if near or past expiration
#   5) Saves the final issues JSON to output
# -----------------------------------------------------------------------------

: "${APP_GATEWAY_NAME:?Must set APP_GATEWAY_NAME}"
: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"

newline=$'\n'
DAYS_THRESHOLD="${DAYS_THRESHOLD:-30}"  # Warn if cert expires within these days
OUTPUT_DIR="${OUTPUT_DIR:-./output}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_FILE="${OUTPUT_DIR}/appgw_ssl_certificate_checks.json"

issues_json='{"issues": []}'

echo "Checking SSL certificates for Application Gateway \`$APP_GATEWAY_NAME\` in Resource Group \`$AZ_RESOURCE_GROUP\`..."
echo "Will warn if certificates expire in the next $DAYS_THRESHOLD days."

# 1) Retrieve App Gateway details
echo "Fetching Application Gateway configuration..."
if ! appgw_json=$(az network application-gateway show \
  --name "$APP_GATEWAY_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  -o json 2>$OUTPUT_DIR/appgw_ssl_err.log); then
  echo "ERROR: Failed to retrieve Application Gateway details."
  error_msg=$(cat $OUTPUT_DIR/appgw_ssl_err.log)
  rm -f $OUTPUT_DIR/appgw_ssl_err.log

  # Log the issue to JSON and exit
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Failed to Fetch App Gateway Config for Application Gateway \`$APP_GATEWAY_NAME\`" \
    --arg details "$error_msg" \
    --arg severity "1" \
    --arg nextStep "Check Azure CLI permissions or resource name correctness." \
    '.issues += [{
       "title": $title,
       "details": $details,
       "next_step": $nextStep,
       "severity": ($severity | tonumber)
     }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 1
fi
rm -f $OUTPUT_DIR/appgw_ssl_err.log

# 2) Parse the sslCertificates array
ssl_certs=$(echo "$appgw_json" | jq -c '.sslCertificates[]?')
if [[ -z "$ssl_certs" ]]; then
  echo "No SSL certificates found in Application Gateway. Possibly using Key Vault references or none configured."
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No SSL Certificates Found for Application Gateway \`$APP_GATEWAY_NAME\`" \
    --arg details "The Application Gateway has no sslCertificates[] array in its config." \
    --arg severity "3" \
    --arg nextStep "If you rely on Key Vault references or no HTTPS listeners, this may be expected $newline Check Configuration Health of Application Gateway \`$APP_GATEWAY_NAME\` In Resource Group \`$AZ_RESOURCE_GROUP\`" \
    '.issues += [{
       "title": $title,
       "details": $details,
       "next_step": $nextStep,
       "severity": ($severity | tonumber)
     }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

# 3) For each cert, check expiry
warn_days="$DAYS_THRESHOLD"
current_time=$(date +%s)   # epoch seconds now

while IFS= read -r cert_json; do
  # Extract name, expiry from the JSON
  cert_name=$(echo "$cert_json" | jq -r '.name // "UnknownCertName"')
  expiry_str=$(echo "$cert_json" | jq -r '.expiry // empty')

  if [[ -z "$expiry_str" || "$expiry_str" == "null" ]]; then
    # Possibly no expiry if using KeyVault or no embedded PFX data
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Cannot Determine Certificate Expiry for Application Gateway \`$APP_GATEWAY_NAME\`" \
      --arg details "SSL certificate \`$cert_name\` does not have an \`expiry\` field." \
      --arg severity "4" \
      --arg nextStep "If using Key Vault references, you must check expiry from Key Vault. Otherwise, re-upload PFX to see expiry." \
      '.issues += [{
         "title": $title,
         "details": $details,
         "next_step": $nextStep,
         "severity": ($severity | tonumber)
       }]')
    continue
  fi

  echo "Found SSL Certificate: $cert_name (Expiry: $expiry_str)"

  # Convert expiry date (like "2025-02-28T23:59:59+00:00") to epoch
  # If the format isn't parseable, you might need to tweak the 'date' command arguments or do custom parsing
  expiry_epoch=$(date -d "$expiry_str" +%s 2>/dev/null || echo 0)

  if [[ "$expiry_epoch" == "0" ]]; then
    # Could not parse date
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Invalid Certificate Expiry Format for Application Gateway \`$APP_GATEWAY_NAME\`" \
      --arg details "Cert \`$cert_name\` has expiry \`$expiry_str\`, which we couldn't parse." \
      --arg severity "1" \
      --arg nextStep "Check date format or parse manually." \
      '.issues += [{
         "title": $title,
         "details": $details,
         "next_step": $nextStep,
         "severity": ($severity | tonumber)
       }]')
    continue
  fi

  # Compute days remaining
  diff_secs=$(( expiry_epoch - current_time ))
  diff_days=$(( diff_secs / 86400 ))  # 86400 seconds in a day

  echo "Days until expiration for $cert_name: $diff_days"

  if (( diff_days < 0 )); then
    # Expired
    issues_json=$(echo "$issues_json" | jq \
      --arg title "SSL Certificate \`$cert_name\` Expired in Application Gateway \`$APP_GATEWAY_NAME\`" \
      --arg details "Certificate \`$cert_name\` expired on $expiry_str (now $diff_days days old)." \
      --arg severity "2" \
      --arg nextStep "Renew and replace certificates immediately for Application Gateway \`$APP_GATEWAY_NAME\` in Resource Group \`$AZ_RESOURCE_GROUP\`." \
      '.issues += [{
         "title": $title,
         "details": $details,
         "next_step": $nextStep,
         "severity": ($severity | tonumber)
       }]')
  elif (( diff_days < warn_days )); then
    # Within threshold
    issues_json=$(echo "$issues_json" | jq \
      --arg title "SSL Certificate \`$cert_name\` Near Expiry in Application Gateway \`$APP_GATEWAY_NAME\`" \
      --arg details "Certificate \`$cert_name\` expires on $expiry_str (only $diff_days days away)." \
      --arg severity "3" \
      --arg nextStep "Initiate SSL certificaet renewal process for Application Gateway \`$APP_GATEWAY_NAME\` in Resource Group \`$AZ_RESOURCE_GROUP\`." \
      '.issues += [{
         "title": $title,
         "details": $details,
         "next_step": $nextStep,
         "severity": ($severity | tonumber)
       }]')
  else
    echo "Certificate \`$cert_name\` is valid for $diff_days more days. No issues."
  fi
done <<< "$ssl_certs"

# 4) Save final JSON
echo "SSL certificate check completed. Saving results to $OUTPUT_FILE"
echo "$issues_json" > "$OUTPUT_FILE"
