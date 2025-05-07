#!/usr/bin/env bash
#
# Check APIM SSL Certificates
# For custom domains and gateway endpoints
#
# Usage:
#   export AZ_RESOURCE_GROUP="myResourceGroup"
#   export APIM_NAME="myApimInstance"
#   # Optionally: export DAYS_THRESHOLD=30 (days before expiry to warn)
#   # Optionally: export AZURE_RESOURCE_SUBSCRIPTION_ID="sub-id"
#   ./check_apim_ssl_certs.sh
#
# Description:
#   1) Retrieve APIM resource details
#   2) Parse hostnameConfigurations to identify custom domains & cert info
#   3) For each domain:
#      - If APIM provides thumbprint/expiration, check it
#      - Otherwise, do a live TLS check (curl) to retrieve the expiration date
#      - Verify domain name matches cert subject/SAN
#   4) Log any issues (expired, near expiry, domain mismatch) to apim_ssl_certificate_issues.json

set -euo pipefail

###############################################################################
# Subscription & environment setup
###############################################################################
if [ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "[INFO] AZURE_RESOURCE_SUBSCRIPTION_ID not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "[INFO] Using specified subscription ID: $subscription"
fi

echo "[INFO] Switching to subscription: $subscription"
az account set --subscription "$subscription"

: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"
: "${APIM_NAME:?Must set APIM_NAME}"

DAYS_THRESHOLD="${DAYS_THRESHOLD:-30}"
OUTPUT_FILE="apim_ssl_certificate_issues.json"
issues_json='{"issues": []}'

echo "[INFO] Checking SSL certs for APIM '$APIM_NAME' in resource group '$AZ_RESOURCE_GROUP'"
echo "[INFO] Expiration warning threshold: $DAYS_THRESHOLD days"

###############################################################################
# Helper: log_issue => appends to issues_json
###############################################################################
log_issue() {
  local title="$1"
  local details="$2"
  local severity="$3"
  local next_steps="$4"

  issues_json=$(echo "$issues_json" | jq \
    --arg t "$title" \
    --arg d "$details" \
    --arg s "$severity" \
    --arg n "$next_steps" \
    '.issues += [{
      "title": $t,
      "details": $d,
      "next_steps": $n,
      "severity": ($s|tonumber)
    }]')
}

###############################################################################
# Helper: live_tls_expiry => attempts to get expiry from a domain via curl -v
#   returns expiry epoch in global var live_expiry_epoch=0 if fail
###############################################################################
live_expiry_epoch=0
live_tls_expiry() {
  local domain="$1"
  live_expiry_epoch=0
  echo "[INFO] Checking live TLS expiry for domain: $domain"

  # We want stderr for the SSL handshake info
  local curl_output
  if ! curl_output="$(curl --insecure -v "https://$domain" 2>&1)"; then
    echo "[WARN] Curl failed for domain '$domain'. Possibly offline or invalid domain."
    return
  fi

  # Example line: "*  expire date: Jul 15 23:59:59 2025 GMT"
  local expire_line
  expire_line=$(echo "$curl_output" | awk '/expire date:/ {print $0; exit}')
  if [[ -z "$expire_line" ]]; then
    echo "[WARN] Could not find 'expire date:' in curl output for $domain."
    return
  fi

  local dt
  dt=$(echo "$expire_line" | sed -E 's/.*expire date:\s*(.*)$/\1/')
  if [[ -z "$dt" ]]; then
    echo "[WARN] Unable to parse date from line '$expire_line'."
    return
  fi

  local e
  e=$(date -d "$dt" +%s 2>/dev/null || echo 0)
  if [[ "$e" -eq 0 ]]; then
    echo "[WARN] Could not convert '$dt' to epoch."
    return
  fi

  live_expiry_epoch="$e"
  echo "[INFO] Live certificate for $domain expires on $(date -d "@$live_expiry_epoch" +'%Y-%m-%d %H:%M:%S %Z')"
}

###############################################################################
# 1) Retrieve APIM resource with hostname configs
###############################################################################
apim_show_err="apim_show_err.log"
if ! apim_json=$(az apim show \
      --resource-group "$AZ_RESOURCE_GROUP" \
      --name "$APIM_NAME" \
      -o json 2>"$apim_show_err"); then
  err_msg=$(cat "$apim_show_err")
  rm -f "$apim_show_err"
  echo "[ERROR] Could not retrieve APIM details."
  log_issue \
    "Failed to Retrieve APIM Resource '$APIM_NAME'" \
    "$err_msg" \
    "1" \
    "Check if APIM name/resource group are correct and you have the correct permissions."
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 1
fi
rm -f "$apim_show_err"

host_configs=$(echo "$apim_json" | jq -c '.hostnameConfigurations // []')
if [[ "$host_configs" == "[]" ]]; then
  echo "[INFO] No hostnameConfigurations found in APIM. Possibly only default domain is used."
  # This is not necessarily an error; if no custom domain is set, there's no custom SSL to check
  log_issue \
    "No Custom Hostname Configurations" \
    "APIM may be using default *.azure-api.net domain or no custom SSL." \
    "4" \
    "If custom domains are needed, configure them with an SSL certificate."
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

echo "[INFO] Found hostnameConfigurations. Parsing..."

###############################################################################
# 2) For each hostname config => domainName, certificate info (thumbprint, expiry, etc.)
###############################################################################
cur_time=$(date +%s)
while IFS= read -r hc; do
  domain_name=$(echo "$hc" | jq -r '.hostName // empty')
  host_type=$(echo "$hc" | jq -r '.hostNameType // empty')
  sni_cert_subject=$(echo "$hc" | jq -r '.certificate?.subject // "No Subject"')
  sni_thumbprint=$(echo "$hc" | jq -r '.certificate?.thumbprint // "UnknownThumbprint"')
  # min TLS version if present
  min_tls=$(echo "$hc" | jq -r '.minTlsVersion? // "N/A"')

  if [[ -z "$domain_name" || "$domain_name" == "null" ]]; then
    continue
  fi
  echo "[INFO] Host: $domain_name (Type: $host_type), Cert Subject: $sni_cert_subject, Thumbprint: $sni_thumbprint, TLS >= $min_tls"

  # If there's an 'expiry' property, APIM includes it in certificate for custom domain
  # Typically not in older versions, but let's check
  expiry_str=$(echo "$hc" | jq -r '.certificate?.expiry? // empty')
  expiry_epoch=0
  if [[ -n "$expiry_str" && "$expiry_str" != "null" ]]; then
    local_e=$(date -d "$expiry_str" +%s 2>/dev/null || echo 0)
    if [[ "$local_e" -gt 0 ]]; then
      expiry_epoch="$local_e"
      echo "[INFO] APIM certificate expiry for $domain_name => $expiry_str"
    fi
  fi

  # If no expiry from APIM, do a live check with curl
  if [[ "$expiry_epoch" -eq 0 ]]; then
    live_tls_expiry "$domain_name"
    if [[ "$live_expiry_epoch" -gt 0 ]]; then
      expiry_epoch="$live_expiry_epoch"
    fi
  fi

  if [[ "$expiry_epoch" -eq 0 ]]; then
    # If we still can't get an expiry, log an informational or warning
    log_issue \
      "Cannot Determine Certificate Expiry for '$domain_name'" \
      "No .expiry from APIM, and live TLS check on '$domain_name' also failed." \
      "4" \
      "If using Key Vault or a custom certificate, ensure logs or separate checks are available."
    continue
  fi

  # Check if domain_name matches the cert subject if we have it
  # This is a simplistic check: does domain_name appear in the subject?
  if [[ "$sni_cert_subject" != "No Subject" ]]; then
    # Example subject: "CN=api.example.com"
    # We can do a rough substring check or parse it more thoroughly
    if ! echo "$sni_cert_subject" | grep -iq "$domain_name"; then
      log_issue \
        "Potential Domain Mismatch for '$domain_name'" \
        "Certificate subject '$sni_cert_subject' does not match domain." \
        "3" \
        "Verify domainName in APIM config matches the certificate's SAN or subject."
    fi
  fi

  # Evaluate days to expiration
  sec_diff=$(( expiry_epoch - cur_time ))
  days_left=$(( sec_diff / 86400 ))
  echo "[INFO] '$domain_name': Days until expiration => $days_left"

  if (( days_left < 0 )); then
    # expired
    log_issue \
      "Certificate for '$domain_name' is Expired" \
      "Expired on $(date -d "@$expiry_epoch" +'%Y-%m-%d %H:%M:%S %Z') ($((-days_left)) days ago)." \
      "2" \
      "Renew or replace certificate for custom domain '$domain_name' in APIM."
  elif (( days_left < DAYS_THRESHOLD )); then
    # near expiry
    log_issue \
      "Certificate for '$domain_name' Nearing Expiry" \
      "Expires in $days_left days ($(date -d "@$expiry_epoch" +'%Y-%m-%d %H:%M:%S %Z'))." \
      "3" \
      "Initiate renewal process for custom domain '$domain_name' in APIM."
  else
    echo "[INFO] Certificate for '$domain_name' is valid for $days_left more days. No issues."
  fi

done <<< "$(echo "$host_configs" | jq -c '.[]?')"

###############################################################################
# 3) Write the final JSON: { "issues": [ ... ] }
###############################################################################
echo "[INFO] Saving results to $OUTPUT_FILE"
echo "$issues_json" > "$OUTPUT_FILE"
