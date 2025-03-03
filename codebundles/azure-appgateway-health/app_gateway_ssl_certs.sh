#!/usr/bin/env bash
# set -euo pipefail

# -----------------------------------------------------------------------------
# ENV VARS REQUIRED:
#   APP_GATEWAY_NAME   (Name of the Application Gateway)
#   AZ_RESOURCE_GROUP  (Resource Group of the Application Gateway)
#
# OPTIONAL:
#   DAYS_THRESHOLD     (Integer) - days before expiry to warn, default=30
#   OUTPUT_DIR         - directory to store the resulting JSON, default=./output
#
# The script:
#   1) Retrieves the Application Gateway JSON
#   2) Identifies *used* SSL certificates from:
#      - .httpListeners[].sslCertificate.id
#      - or .listeners[].sslCertificateId (fallback if .httpListeners is empty)
#      - or .sslProfile references
#   3) Checks the .expiry field or queries ssl-cert show => .publicCertData
#   4) Fallback to live TLS checks in this order:
#      a) If a listener has a hostname (SNI), curl https://<hostname>
#      b) Otherwise, or if that fails, use the gateway’s public IP or DNS
#   5) Logs issues if near/past expiration or unknown
#   6) Skips certs not in use
# -----------------------------------------------------------------------------

: "${APP_GATEWAY_NAME:?Must set APP_GATEWAY_NAME}"
: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"

newline=$'\n'
DAYS_THRESHOLD="${DAYS_THRESHOLD:-30}"
OUTPUT_DIR="${OUTPUT_DIR:-./output}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_FILE="${OUTPUT_DIR}/appgw_ssl_certificate_checks.json"

issues_json='{"issues": []}'

echo "Checking SSL certificates for AppGw \`$APP_GATEWAY_NAME\` in RG \`$AZ_RESOURCE_GROUP\`..."
echo "Will warn if certificates expire in < $DAYS_THRESHOLD days."

##################################
# Helper: log an issue to JSON
##################################
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

##################################
# Function: parse 'publicCertData' => expiry epoch
# Output in global var parse_epoch=0 if fail
##################################
parse_epoch=0
parse_public_cert_data() {
  local cert_data="$1"
  parse_epoch=0

  # if it's raw PEM with 'BEGIN CERTIFICATE'
  if [[ "$cert_data" =~ "BEGIN CERTIFICATE" ]]; then
    local cert_pem="$cert_data"
    local end_date
    end_date=$(echo "$cert_pem" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    if [[ -n "$end_date" ]]; then
      local e
      e=$(date -d "$end_date" +%s 2>/dev/null || echo 0)
      parse_epoch="$e"
    fi
    return
  fi

  # Otherwise, assume it's base64
  local tmpfile
  tmpfile=./tmpcert
  echo "$cert_data" | base64 -d > "$tmpfile" 2>/dev/null || true

  # (1) Try DER -> PEM
  local der_pem
  der_pem=$(openssl x509 -in "$tmpfile" -inform DER -outform PEM 2>/dev/null || echo '')
  if [[ -n "$der_pem" ]]; then
    local end_date
    end_date=$(echo "$der_pem" | openssl x509 -noout -enddate | cut -d= -f2)
    if [[ -n "$end_date" ]]; then
      local e
      e=$(date -d "$end_date" +%s 2>/dev/null || echo 0)
      parse_epoch="$e"
    fi
    rm -f "$tmpfile"
    return
  fi

  # (2) Try no-pass PFX
  local pfx_pem
  pfx_pem=$(openssl pkcs12 -in "$tmpfile" -nokeys -clcerts -passin pass: 2>/dev/null | openssl x509 -outform PEM 2>/dev/null || echo '')
  if [[ -n "$pfx_pem" ]]; then
    local end_date
    end_date=$(echo "$pfx_pem" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    if [[ -n "$end_date" ]]; then
      local e
      e=$(date -d "$end_date" +%s 2>/dev/null || echo 0)
      parse_epoch="$e"
    fi
  fi
  rm -f "$tmpfile"
}

##################################
# Function: parse live certificate expiry
# from 'curl --insecure -v https://<hostnameOrIp>'
# Return epoch in global var fallback_epoch=0 if fail
##################################
fallback_epoch=0
parse_live_tls_expiry() {
  local target="$1"
  fallback_epoch=0

  echo "Trying live TLS check on: $target"
  local curl_output
  # We need both stdout and stderr, because curl logs SSL handshake to stderr
  if ! curl_output="$(curl --insecure -v "https://$target" 2>&1)"; then
    echo "curl failed on $target. Possibly no listener or unreachable."
    return
  fi

  # Typically: "*  expire date: Jul 15 23:59:59 2025 GMT"
  local expire_line
  expire_line=$(echo "$curl_output" | awk '/expire date:/ {print $0; exit}')
  if [[ -z "$expire_line" ]]; then
    echo "No 'expire date:' line found for $target."
    return
  fi

  # Parse out the date portion
  local expire_str
  expire_str=$(echo "$expire_line" | sed -E 's/.*expire date:\s*(.*)$/\1/')
  if [[ -z "$expire_str" ]]; then
    echo "Could not parse expiry from line '$expire_line'."
    return
  fi

  local e
  e=$(date -d "$expire_str" +%s 2>/dev/null || echo 0)
  if [[ "$e" -eq 0 ]]; then
    echo "Could not convert date '$expire_str' to epoch for $target."
    return
  fi

  fallback_epoch="$e"
}

##################################
# 1) Retrieve the AppGw main JSON
##################################
echo "Fetching Application Gateway configuration..."
OUTPUT_ERR="$OUTPUT_DIR/appgw_err.log"
if ! appgw_json=$(az network application-gateway show \
  --name "$APP_GATEWAY_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  -o json 2>"$OUTPUT_ERR"); then
  error_msg=$(cat "$OUTPUT_ERR")
  rm -f "$OUTPUT_ERR"
  log_issue \
    "Failed to Fetch AppGw \`$APP_GATEWAY_NAME\`" \
    "$error_msg" \
    "1" \
    "Check CLI permissions or resource name correctness."
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 1
fi
rm -f "$OUTPUT_ERR"

##################################
# DEBUG: Dump some partial JSON
##################################
echo "DEBUG: Dumping .httpListeners, .listeners => $OUTPUT_DIR/listeners_debug.json"
echo "$appgw_json" | jq '{httpListeners: .httpListeners, listeners: .listeners}' > "$OUTPUT_DIR/listeners_debug.json"

##################################
# 2) Identify "effective" array of listeners
##################################
http_listeners_json=$(echo "$appgw_json" | jq -c '.httpListeners // []')
if [[ "$http_listeners_json" == "[]" ]]; then
  echo "No .httpListeners found; checking .listeners instead..."
  http_listeners_json=$(echo "$appgw_json" | jq -c '.listeners // []')
  if [[ "$http_listeners_json" == "[]" ]]; then
    echo "No .listeners either. Exiting."
    log_issue \
      "No Listeners Found" \
      "No .httpListeners or .listeners in AppGw JSON. Possibly a different API version." \
      "3" \
      "Check the raw JSON in Azure Portal or use a different approach."
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 0
  fi
fi

##################################
# 2A) Collect any hostnames from the listeners
#     For SNI-based listeners, Azure stores "hostName" or "hostNames"
##################################
declare -A listener_hostnames_map
# We'll store: listener_name => "host1 host2..."

while IFS= read -r obj; do
  name=$(echo "$obj" | jq -r '.name // empty')
  [[ -z "$name" || "$name" == "null" ]] && continue

  # For legacy or single, might be .hostName
  single=$(echo "$obj" | jq -r '.hostName // empty')
  if [[ -n "$single" && "$single" != "null" ]]; then
    listener_hostnames_map["$name"]="$single"
  fi

  # For newer ones, might be .hostNames[] (array)
  arr=$(echo "$obj" | jq -r '.hostNames[]?')
  if [[ -n "$arr" ]]; then
    # combine space delimited
    # If there's already a single hostName in the map, we'll append
    combined="${listener_hostnames_map["$name"]}"
    while IFS= read -r h; do
      combined="$combined $h"
    done <<< "$arr"
    # Trim leading/trailing spaces
    combined="$(echo "$combined" | xargs)"
    listener_hostnames_map["$name"]="$combined"
  fi
done < <(echo "$http_listeners_json" | jq -c '.[]?')

##################################
# 3) Build a list of used cert names
#    from .sslCertificate or .sslCertificateId
#    plus .sslProfile references
##################################
direct_cert_names=()

while IFS= read -r obj; do
  ssl_cert_id=$(echo "$obj" | jq -r '( .sslCertificate?.id // .sslCertificateId // "" ) | select(. != null)')
  [[ -z "$ssl_cert_id" || "$ssl_cert_id" == "null" ]] && continue

  c_name=$(echo "$ssl_cert_id" | sed -E 's|.*/sslCertificates/([^/]+)$|\1|')
  [[ -n "$c_name" ]] && direct_cert_names+=("$c_name")
done < <(echo "$http_listeners_json" | jq -c '.[]?')

# Collect SSL profiles if present
declare -A ssl_profile_id_to_name
while IFS= read -r prof_json; do
  p_id=$(echo "$prof_json" | jq -r '.id // empty')
  p_nm=$(echo "$prof_json" | jq -r '.name // empty')
  [[ -n "$p_id" && -n "$p_nm" ]] && ssl_profile_id_to_name["$p_id"]="$p_nm"
done < <(echo "$appgw_json" | jq -c '.sslProfiles[]?')

# build map from profileName => space-delimited cert IDs
declare -A ssl_profile_certs_map
while IFS= read -r prof_json; do
  nm=$(echo "$prof_json" | jq -r '.name // empty')
  [[ -z "$nm" ]] && continue
  cert_ids=$(echo "$prof_json" | jq -r '.sslCertificates[]?')
  c_list=()
  if [[ -n "$cert_ids" ]]; then
    while IFS= read -r cid; do
      c_list+=("$cid")
    done <<< "$cert_ids"
    ssl_profile_certs_map["$nm"]="${c_list[*]}"
  fi
done < <(echo "$appgw_json" | jq -c '.sslProfiles[]?')

profile_based_certs=()
# For each listener, see if there's .sslProfile
while IFS= read -r obj; do
  ssl_prof_id=$(echo "$obj" | jq -r '( .sslProfile?.id // .sslProfileId // "" ) | select(. != null)')
  [[ -z "$ssl_prof_id" || "$ssl_prof_id" == "null" ]] && continue

  prof_name="${ssl_profile_id_to_name["$ssl_prof_id"]}"
  [[ -z "$prof_name" ]] && continue

  # now get the cert IDs from ssl_profile_certs_map
  cert_ids_str="${ssl_profile_certs_map["$prof_name"]}"
  if [[ -n "$cert_ids_str" ]]; then
    for cid in $cert_ids_str; do
      c_name=$(echo "$cid" | sed -E 's|.*/sslCertificates/([^/]+)$|\1|')
      [[ -n "$c_name" ]] && profile_based_certs+=("$c_name")
    done
  fi
done < <(echo "$http_listeners_json" | jq -c '.[]?')

all_used_certs=()
all_used_certs+=("${direct_cert_names[@]}")
all_used_certs+=("${profile_based_certs[@]}")
all_used_certs=( $(printf "%s\n" "${all_used_certs[@]}" | sort -u) )

if [[ "${#all_used_certs[@]}" -eq 0 ]]; then
  echo "No SSL cert references found in .sslCertificate or .sslProfile."
  log_issue \
    "No SSL Certificates in Use" \
    "Listeners do not reference any sslCertificate or sslProfile." \
    "3" \
    "If using Key Vault or plain HTTP, this may be expected."
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

echo "Discovered in-use certificate names: ${all_used_certs[*]}"

##################################
# For the fallback, also retrieve
# the public IP / DNS name if present
##################################
fallback_gw_ip_or_dns=''
public_ip_id=$(echo "$appgw_json" | jq -r '.frontendIPConfigurations[]? | select(.publicIPAddress != null) | .publicIPAddress.id // empty' | head -n1)
if [[ -n "$public_ip_id" ]]; then
  pip_json=$(az network public-ip show --ids "$public_ip_id" -o json 2>/dev/null || echo '')
  if [[ -n "$pip_json" ]]; then
    raw_ip=$(echo "$pip_json" | jq -r '.ipAddress // empty')
    if [[ -n "$raw_ip" && "$raw_ip" != "null" ]]; then
      fallback_gw_ip_or_dns="$raw_ip"
    else
      raw_dns=$(echo "$pip_json" | jq -r '.dnsSettings.fqdn // empty')
      if [[ -n "$raw_dns" && "$raw_dns" != "null" ]]; then
        fallback_gw_ip_or_dns="$raw_dns"
      fi
    fi
  fi
fi
echo "Public IP or DNS fallback: $fallback_gw_ip_or_dns"

##################################
# 4) Parse .sslCertificates[] from the AppGw config
##################################
ssl_certs_json=$(echo "$appgw_json" | jq -c '.sslCertificates[]?')
if [[ -z "$ssl_certs_json" ]]; then
  echo "No .sslCertificates[] in AppGw. Possibly Key Vault only?"
  log_issue \
    "No sslCertificates[] in AppGw" \
    "The AppGw has no sslCertificates[] array in its config." \
    "3" \
    "If Key Vault references are used, parse from Key Vault or fallback to live check."
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

warn_days="$DAYS_THRESHOLD"
current_time=$(date +%s)

##################################
# 5) For each in-use cert, parse:
#   (A) .expiry
#   (B) ssl-cert show -> publicCertData
#   (C) fallback live checks:
#       1) hostnames from the listener
#       2) if no hostname or all fail, gateway's public IP
##################################
while IFS= read -r cert_json; do
  c_name=$(echo "$cert_json" | jq -r '.name // "UnknownCertName"')

  # skip if not in use
  if ! printf "%s\n" "${all_used_certs[@]}" | grep -Fxq "$c_name"; then
    continue
  fi
  echo "Processing in-use certificate: $c_name"
  expiry_epoch=0

  # (A) .expiry
  expiry_str=$(echo "$cert_json" | jq -r '.expiry // empty')
  if [[ -n "$expiry_str" && "$expiry_str" != "null" ]]; then
    local_e=$(date -d "$expiry_str" +%s 2>/dev/null || echo 0)
    if [[ "$local_e" -gt 0 ]]; then
      expiry_epoch="$local_e"
      echo "Found .expiry for $c_name => $expiry_str"
    fi
  fi

  # (B) If no valid epoch yet, call ssl-cert show
  if [[ "$expiry_epoch" == "0" ]]; then
    echo "No valid .expiry, calling ssl-cert show for $c_name..."
    show_err="$OUTPUT_DIR/ssl_cert_show_err.log"
    ssl_show_json=$(az network application-gateway ssl-cert show \
      --resource-group "$AZ_RESOURCE_GROUP" \
      --gateway-name "$APP_GATEWAY_NAME" \
      --name "$c_name" -o json 2>"$show_err" || echo '')
    if [[ -n "$ssl_show_json" ]]; then
      rm -f "$show_err"
      pub_cert_data=$(echo "$ssl_show_json" | jq -r '.publicCertData // empty')
      if [[ -n "$pub_cert_data" && "$pub_cert_data" != "null" ]]; then
        parse_public_cert_data "$pub_cert_data"
        if [[ "$parse_epoch" -gt 0 ]]; then
          expiry_epoch="$parse_epoch"
          echo "Parsed expiry for $c_name via publicCertData => $(date -d "@$expiry_epoch")"
        fi
      else
        echo "ssl-cert show => no publicCertData for $c_name"
      fi
    else
      err_msg=$(cat "$show_err" 2>/dev/null || echo '')
      rm -f "$show_err"
      echo "ssl-cert show failed for $c_name => $err_msg"
    fi
  fi

  # (C) If still zero, do fallback live checks
  if [[ "$expiry_epoch" == "0" ]]; then
    echo "No expiry from config; trying a live TLS check for $c_name..."

    # 1) Find any listener(s) that reference this certificate, gather hostnames
    #    Then attempt each
    # We'll parse the entire list again (inefficient but simple),
    # checking if .sslCertificate or .sslProfile resolves to c_name
    # then collecting hostnames from listener_hostnames_map

    success=0
    # gather all potential hostnames
    all_listener_hostnames=""
    while IFS= read -r obj; do
      lst_name=$(echo "$obj" | jq -r '.name // empty')
      [[ -z "$lst_name" || "$lst_name" == "null" ]] && continue

      # Does this listener reference c_name?
      # either direct or via sslProfile?
      sc_id=$(echo "$obj" | jq -r '( .sslCertificate?.id // .sslCertificateId // "" ) | select(. != null)')
      prof_id=$(echo "$obj" | jq -r '( .sslProfile?.id // .sslProfileId // "" ) | select(. != null)')

      ref_names=()
      # direct?
      if [[ -n "$sc_id" && "$sc_id" != "null" ]]; then
        sc_parsed=$(echo "$sc_id" | sed -E 's|.*/sslCertificates/([^/]+)$|\1|')
        ref_names+=("$sc_parsed")
      fi
      # profile?
      if [[ -n "$prof_id" && "$prof_id" != "null" ]]; then
        # map profile => certs
        pf_nm="${ssl_profile_id_to_name["$prof_id"]}"
        if [[ -n "$pf_nm" ]]; then
          cids="${ssl_profile_certs_map["$pf_nm"]}"
          if [[ -n "$cids" ]]; then
            for x in $cids; do
              xnm=$(echo "$x" | sed -E 's|.*/sslCertificates/([^/]+)$|\1|')
              ref_names+=("$xnm")
            done
          fi
        fi
      fi

      # If c_name is in ref_names, we gather hostnames from listener_hostnames_map
      if printf "%s\n" "${ref_names[@]}" | grep -Fxq "$c_name"; then
        hlist="${listener_hostnames_map["$lst_name"]}"
        if [[ -n "$hlist" ]]; then
          all_listener_hostnames="$all_listener_hostnames $hlist"
        fi
      fi
    done < <(echo "$http_listeners_json" | jq -c '.[]?')

    all_listener_hostnames="$(echo "$all_listener_hostnames" | xargs)"  # trim
    if [[ -n "$all_listener_hostnames" ]]; then
      # try each unique hostname
      unique_hosts=( $(printf "%s\n" $all_listener_hostnames | sort -u) )
      for h in "${unique_hosts[@]}"; do
        parse_live_tls_expiry "$h"
        if [[ "$fallback_epoch" -gt 0 ]]; then
          expiry_epoch="$fallback_epoch"
          success=1
          echo "Got expiry via live check on $h => $(date -d "@$expiry_epoch")"
          break
        fi
      done
    fi

    # 2) If still not found and we have a public IP, try that
    if [[ "$success" -eq 0 && -n "$fallback_gw_ip_or_dns" ]]; then
      parse_live_tls_expiry "$fallback_gw_ip_or_dns"
      if [[ "$fallback_epoch" -gt 0 ]]; then
        expiry_epoch="$fallback_epoch"
        success=1
        echo "Got expiry via fallback IP check => $(date -d "@$expiry_epoch")"
      fi
    fi

    if [[ "$success" -eq 0 ]]; then
      log_issue \
        "Cannot Determine Cert Expiry for \`$c_name\`" \
        "No .expiry, no parseable publicCertData, and live checks to hostnames/IP failed." \
        "4" \
        "If using Key Vault or a passworded PFX, query Key Vault or re-upload a parseable cert."
      continue
    fi
  fi

  # We have expiry_epoch now, compare
  diff_secs=$(( expiry_epoch - current_time ))
  diff_days=$(( diff_secs / 86400 ))
  echo "Days until expiration for $c_name: $diff_days"

  if (( diff_days < 0 )); then
    log_issue \
      "SSL Certificate \`$c_name\` Expired" \
      "Expired on $(date -d "@$expiry_epoch" +'%Y-%m-%d %H:%M:%S %Z') ($((-diff_days)) days ago)." \
      "2" \
      "Renew or replace immediately."
  elif (( diff_days < warn_days )); then
    log_issue \
      "SSL Certificate \`$c_name\` Near Expiry" \
      "Expires in $diff_days days ($(date -d "@$expiry_epoch" +'%Y-%m-%d %H:%M:%S %Z'))." \
      "3" \
      "Initiate renewal process for SSL Certificates In App Gateway \`$APP_GATEWAY_NAME\` in \`$AZ_RESOURCE_GROUP\`"
  else
    echo "Certificate \`$c_name\` is valid for $diff_days more days. No issues."
  fi

done <<< "$ssl_certs_json"

##################################
# 6) Output final JSON
##################################
echo "SSL certificate check completed. Saving results to $OUTPUT_FILE"
echo "$issues_json" > "$OUTPUT_FILE"
