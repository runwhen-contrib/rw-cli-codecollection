#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee Target Server and Virtual Host Configuration
#
# Reviews target servers for missing/incorrect TLS (sSLInfo) configuration,
# flagging plaintext or insecurely-configured backends. Also performs a
# best-effort check of virtual host configuration.
#
# NOTE: The Apigee Admin API does not currently expose a public REST endpoint
# for enumerating virtual hosts. This script therefore focuses on target
# servers (which ARE documented) and only parses virtual host data if the API
# happens to return it; the absence of a public endpoint is not treated as an
# issue.
#
# REQUIRED ENV VARS:
#   APIGEE_ORG                    - Apigee organization name
#   GCP_PROJECT_ID                - GCP project ID hosting the Apigee runtime
#
# AUTH:
#   gcloud must be authenticated; token obtained via `gcloud auth print-access-token`.
#
# OUTPUTS:
#   target_vhost_issues.json - JSON array of issue objects
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${APIGEE_ORG:?Must set APIGEE_ORG}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="target_vhost_issues.json"
API="https://apigee.googleapis.com/v1"

echo "Checking target server / virtual host configuration for org: $APIGEE_ORG"

TOKEN=$(gcloud auth print-access-token 2>/dev/null || gcloud auth application-default print-access-token 2>/dev/null || echo "")
if [ -z "$TOKEN" ]; then
  echo "Error: unable to obtain an access token." >&2
  printf '[{"title":"Cannot access Apigee target server data","details":"Unable to obtain a GCP access token for org `%s`.","severity":3,"expected":"Apigee API access should be authenticated","actual":"No access token available","next_steps":"Verify the service account is authenticated and has roles/apigee.readOnlyAdmin."}]\n' "$APIGEE_ORG" > "$OUTPUT_FILE"
  exit 0
fi

fetch_env_list()
{
  local raw
  raw=$(curl -s -H "Authorization: Bearer $TOKEN" "$API/organizations/$APIGEE_ORG/environments")
  printf '%s' "$raw" | jq -c 'if type=="array" then . elif .environment != null then .environment else [] end' 2>/dev/null || echo "[]"
}

environments=$(fetch_env_list)
if [ "$(printf '%s' "$environments" | jq 'if type=="array" then .|length else 0 end' 2>/dev/null)" -eq 0 ]; then
  echo "No environments found for org $APIGEE_ORG."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

> "$OUTPUT_FILE"

printf '%s' "$environments" | jq -c '.[]' 2>/dev/null | while read -r env_name; do
  echo "  Checking environment: $env_name"

  # --- Target servers ---
  raw=$(curl -s -H "Authorization: Bearer $TOKEN" "$API/organizations/$APIGEE_ORG/environments/$env_name/targetservers")
  targets=$(printf '%s' "$raw" | jq -c 'if type=="array" then . elif .targetservers != null then .targetservers else [] end' 2>/dev/null || echo "[]")
  target_count=$(printf '%s' "$targets" | jq 'if type=="array" then length else 0 end' 2>/dev/null)
  echo "    Target servers: $target_count"

  printf '%s' "$targets" | jq -c '.[]' 2>/dev/null | while read -r ts; do
    ts_name=$(printf '%s' "$ts" | jq -r '.name // empty')
    ts_host=$(printf '%s' "$ts" | jq -r '.host // empty')
    ts_port=$(printf '%s' "$ts" | jq -r '.port // empty')
    ts_enabled=$(printf '%s' "$ts" | jq -r '.isEnabled // empty' 2>/dev/null)
    ssl_info=$(printf '%s' "$ts" | jq -c '.sSLInfo // .sslInfo // empty' 2>/dev/null)
    ssl_enabled=$(printf '%s' "$ssl_info" | jq -r '.enabled // empty' 2>/dev/null)

    echo "    Target server $ts_name ($ts_host:$ts_port) sSLInfo.enabled=$ssl_enabled isEnabled=$ts_enabled"

    # Plaintext / missing TLS
    if [ -z "$ssl_enabled" ] || [ "$ssl_enabled" = "false" ]; then
      jq -n \
        --arg title "Apigee target server \`$ts_name\` is not TLS-enabled (plaintext backend)" \
        --arg details "Target server '$ts_name' ($ts_host:$ts_port) in environment '$env_name' of org '$APIGEE_ORG' has no TLS (sSLInfo.enabled is false/absent). Traffic to this backend is unencrypted, exposing sensitive data in transit." \
        --arg severity "3" \
        --arg expected "Target servers should use TLS (sSLInfo.enabled = true) to encrypt traffic" \
        --arg actual "Target server has sSLInfo.enabled=$ssl_enabled" \
        --arg next_steps "Enable TLS on target server '$ts_name' by configuring a keystore/truststore in its sSLInfo, or ensure a load balancer terminates TLS in front of it." \
        --arg env "$env_name" --arg target "$ts_name" \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps,env:$env,targetserver:$target,issue_type:"plaintext_target_server"}' >> "$OUTPUT_FILE"
    fi
  done

  # --- Virtual hosts (best effort; no public REST endpoint) ---
  vh=$(curl -s -H "Authorization: Bearer $TOKEN" "$API/organizations/$APIGEE_ORG/environments/$env_name/virtualhosts")
  vh_valid=$(printf '%s' "$vh" | jq 'if type=="array" then length elif .virtualHost != null then (.virtualHost|length) else 0 end' 2>/dev/null || echo 0)
  if [ "$vh_valid" -gt 0 ] 2>/dev/null; then
    echo "    Virtual host data returned for env $env_name (best-effort)."
  else
    echo "    Virtual host data not available via the Admin API for env $env_name (no public endpoint)."
  fi
done

if [ -s "$OUTPUT_FILE" ]; then
  jq -s '.' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "Target server / virtual host check complete. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
