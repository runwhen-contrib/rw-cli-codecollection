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
#   2) Collects all SSL certificate names actually used by HTTP listeners
#   3) Iterates over those sslCertificates[] in its config
#   4) Checks:
#       - .expiry from the main AppGw config if present
#         OR
#       - Falls back to calling 'az network application-gateway ssl-cert show'
#         and parsing the 'publicCertData' if .expiry is missing
#   5) Logs an issue if near or past expiration
#   6) Saves the final issues JSON to output
# -----------------------------------------------------------------------------

: "${APP_GATEWAY_NAME:?Must set APP_GATEWAY_NAME}"
: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"

newline=$'\n'
DAYS_THRESHOLD="${DAYS_THRESHOLD:-30}"  # Warn if cert expires within these days
OUTPUT_DIR="${OUTPUT_DIR:-./output}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_FILE="${OUTPUT_DIR}/appgw_ssl_certificate_checks.json"

issues_json='{"issues": []}'

echo "Checking *used* SSL certificates for Application Gateway \`$APP_GATEWAY_NAME\` in Resource Group \`$AZ_RESOURCE_GROUP\`..."
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

# 2) Collect the names of SSL certs that are referenced by an HTTP listener
listener_cert_names=$(echo "$appgw_json" | \
  jq -r '
    .httpListeners[]? 
    | select(.sslCertificate != null) 
    | .sslCertificate.id
    | capture(".*/(?<certName>[^/]+$)").certName
  ')

if [[ -z "$listener_cert_names" ]]; then
  echo "No HTTP listeners found that reference an SSL certificate in this Application Gateway."
  echo "Either no HTTPS listeners are configured or certificates are in Key Vault references."
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No SSL Certificates in Use by Application Gateway \`$APP_GATEWAY_NAME\`" \
    --arg details "No .httpListeners[] reference an SSL certificate within the App Gateway config." \
    --arg severity "3" \
    --arg nextStep "If the gateway is configured for plain HTTP or has Key Vault references, this may be expected. Otherwise, check config." \
    '.issues += [{
       "title": $title,
       "details": $details,
       "next_step": $nextStep,
       "severity": ($severity | tonumber)
     }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

# Turn that list into an array for easy membership checks in bash
IFS=$'\n' read -rd '' -a used_certs_array <<<"$listener_cert_names" || true

# 3) Parse the entire sslCertificates array
all_ssl_certs=$(echo "$appgw_json" | jq -c '.sslCertificates[]?')
if [[ -z "$all_ssl_certs" ]]; then
  echo "No SSL certificates found in the Application Gateway config at all."
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No SSL Certificates Found for Application Gateway \`$APP_GATEWAY_NAME\`" \
    --arg details "The Application Gateway has no sslCertificates[] array in its config." \
    --arg severity "3" \
    --arg nextStep "If you rely on Key Vault references or have no HTTPS listeners, this may be expected.$newline Check the gateway configuration." \
    '.issues += [{
       "title": $title,
       "details": $details,
       "next_step": $nextStep,
       "severity": ($severity | tonumber)
     }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

warn_days="$DAYS_THRESHOLD"
current_time=$(date +%s)   # epoch seconds now

# Helper function to log issues
log_issue() {
  local issue_title="$1"
  local issue_details="$2"
  local issue_severity="$3"
  local issue_next_step="$4"

  issues_json=$(echo "$issues_json" | jq \
    --arg title "$issue_title" \
    --arg details "$issue_details" \
    --arg severity "$issue_severity" \
    --arg nextStep "$issue_next_step" \
    '.issues += [{
       "title": $title,
       "details": $details,
       "next_step": $nextStep,
       "severity": ($severity | tonumber)
     }]')
}

# 4) Iterate over the sslCertificates *in use* in the top-level config
while IFS= read -r cert_json; do
  # Extract name, expiry from the JSON
  cert_name=$(echo "$cert_json" | jq -r '.name // "UnknownCertName"')

  # Skip if this certificate isn't in the used_certs_array
  if ! printf "%s\n" "${used_certs_array[@]}" | grep -Fxq "$cert_name"; then
    continue
  fi

  expiry_str=$(echo "$cert_json" | jq -r '.expiry // empty')

  # We'll store the final expiry date in epoch form here
  expiry_epoch=0

  # If there's an expiry in the main AppGw JSON, use that
  if [[ -n "$expiry_str" && "$expiry_str" != "null" ]]; then
    # Attempt to parse the date
    expiry_epoch=$(date -d "$expiry_str" +%s 2>/dev/null || echo 0)
    if [[ "$expiry_epoch" == "0" ]]; then
      log_issue \
        "Invalid Certificate Expiry Format for Application Gateway \`$APP_GATEWAY_NAME\`" \
        "Cert \`$cert_name\` has expiry \`$expiry_str\` which we couldn't parse." \
        "1" \
        "Check date format or parse manually."
      continue
    fi

    echo "Found SSL Certificate with .expiry in config: $cert_name (Expiry: $expiry_str)"
  else
    # 4b) If no .expiry in top-level JSON, call ssl-cert show to get publicCertData
    echo "No .expiry found for certificate \`$cert_name\`. Fetching details via CLI..."

    ssl_show_json=$(az network application-gateway ssl-cert show \
      --resource-group "$AZ_RESOURCE_GROUP" \
      --gateway-name "$APP_GATEWAY_NAME" \
      --name "$cert_name" \
      -o json 2>$OUTPUT_DIR/ssl_cert_show_err.log || echo '')

    # Check if the command succeeded
    if [[ -z "$ssl_show_json" ]]; then
      error_msg=$(cat $OUTPUT_DIR/ssl_cert_show_err.log 2>/dev/null || echo "Unknown error")
      rm -f $OUTPUT_DIR/ssl_cert_show_err.log

      log_issue \
        "Failed to Fetch SSL-Cert Show Data for \`$cert_name\`" \
        "$error_msg" \
        "1" \
        "Check if the certificate name is correct or if you have permissions to retrieve it."
      continue
    fi
    rm -f $OUTPUT_DIR/ssl_cert_show_err.log

    # Extract the publicCertData
    public_cert_data=$(echo "$ssl_show_json" | jq -r '.publicCertData // empty')
    if [[ -z "$public_cert_data" || "$public_cert_data" == "null" ]]; then
      # Possibly a Key Vault reference or something else
      log_issue \
        "Cannot Determine Certificate Expiry for Application Gateway \`$APP_GATEWAY_NAME\`" \
        "SSL certificate \`$cert_name\` has no \`expiry\` in config nor \`publicCertData\` from 'ssl-cert show'." \
        "4" \
        "If using Key Vault references, check expiry from Key Vault. Otherwise, re-upload PFX to see expiry."
      continue
    fi

    # Decode and parse the certificate to find its notAfter date
    # Note: On some distros, 'base64 -d' might be 'base64 --decode'
    # Then we convert from DER to PEM, so openssl can read it easily.
    cert_pem="$(echo "$public_cert_data" | base64 -d 2>/dev/null | openssl x509 -inform DER -outform PEM 2>/dev/null || echo '')"

    if [[ -z "$cert_pem" ]]; then
      log_issue \
        "Failed to Decode Public Cert for \`$cert_name\`" \
        "We got \`publicCertData\` but could not decode/parse it via openssl. Possibly not DER format?" \
        "1" \
        "Manually verify the base64/DER data or check if it's a Key Vault reference."
      continue
    fi

    # Extract the 'notAfter' date (end of validity)
    # Example output: "notAfter=Jul 15 23:59:59 2025 GMT"
    end_date_str="$(echo "$cert_pem" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"

    if [[ -z "$end_date_str" ]]; then
      log_issue \
        "Failed to Extract notAfter Date from Public Cert for \`$cert_name\`" \
        "openssl succeeded in decoding, but no 'notAfter' field was found." \
        "1" \
        "Manually inspect the certificate data or re-check the certificate format."
      continue
    fi

    # Convert that date to epoch
    # e.g. "Jul 15 23:59:59 2025 GMT"
    expiry_epoch=$(date -d "$end_date_str" +%s 2>/dev/null || echo 0)

    if [[ "$expiry_epoch" == "0" ]]; then
      log_issue \
        "Invalid 'notAfter' Date from Public Cert for \`$cert_name\`" \
        "We found notAfter='$end_date_str' but could not parse it via 'date'." \
        "1" \
        "Check date format or parse manually."
      continue
    fi

    echo "Fetched SSL Certificate \`$cert_name\` from CLI (Expiry: $end_date_str)"
  fi

  # If we got here, we have a valid expiry_epoch
  diff_secs=$(( expiry_epoch - current_time ))
  diff_days=$(( diff_secs / 86400 ))

  echo "Days until expiration for $cert_name: $diff_days"

  if (( diff_days < 0 )); then
    # Expired
    log_issue \
      "SSL Certificate \`$cert_name\` Expired in Application Gateway \`$APP_GATEWAY_NAME\`" \
      "Certificate \`$cert_name\` expired on $(date -d "@$expiry_epoch" +'%Y-%m-%d %H:%M:%S %Z') ($((-diff_days)) days ago)." \
      "2" \
      "Renew and replace certificates immediately for Application Gateway \`$APP_GATEWAY_NAME\` in Resource Group \`$AZ_RESOURCE_GROUP\`."
  elif (( diff_days < warn_days )); then
    # Within threshold
    log_issue \
      "SSL Certificate \`$cert_name\` Near Expiry in Application Gateway \`$APP_GATEWAY_NAME\`" \
      "Certificate \`$cert_name\` expires in $diff_days days (on $(date -d "@$expiry_epoch" +'%Y-%m-%d %H:%M:%S %Z'))." \
      "3" \
      "Initiate SSL certificate renewal process for Application Gateway \`$APP_GATEWAY_NAME\` in Resource Group \`$AZ_RESOURCE_GROUP\`."
  else
    echo "Certificate \`$cert_name\` is valid for $diff_days more days. No issues."
  fi

done <<< "$all_ssl_certs"

# 5) Save final JSON
echo "SSL certificate check completed. Saving results to $OUTPUT_FILE"
echo "$issues_json" > "$OUTPUT_FILE"
