#!/usr/bin/env bash
# Runs egress connectivity probes (Network Watcher test-connectivity, skip, or bastion-agent placeholder).
# Writes subnet_probe_issues.json and subnet_probe_results.json
set -euo pipefail
set -x

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${VNET_NAME:?Must set VNET_NAME}"
: "${PROBE_TARGETS:?Must set PROBE_TARGETS}"

OUTPUT_FILE="subnet_probe_issues.json"
RESULTS_JSON="subnet_probe_results.json"
PROBE_MODE="${PROBE_MODE:-network-watcher}"
SOURCE_VM_RESOURCE_ID="${SOURCE_VM_RESOURCE_ID:-}"

issues_json='[]'
results_json='[]'

az account set --subscription "$AZURE_SUBSCRIPTION_ID" 2>/dev/null || true

if [ "$PROBE_MODE" = "skip-probes" ]; then
  echo "PROBE_MODE=skip-probes: connectivity probes skipped (rules-only validation)."
  echo "$issues_json" > "$OUTPUT_FILE"
  echo "$results_json" > "$RESULTS_JSON"
  exit 0
fi

if [ "$PROBE_MODE" = "bastion-agent" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Bastion/agent probe mode requires manual execution" \
    --arg details "PROBE_MODE=bastion-agent is not automated here. Run curl/HTTPS from a jump host or test VM in the subnet and compare to policy." \
    --arg severity "2" \
    --arg next_steps "Use Azure Bastion or a probe VM in the subnet; set PROBE_MODE=network-watcher with SOURCE_VM_RESOURCE_ID for automated tests." \
    '. += [{
      "title": $title,
      "details": $details,
      "severity": ($severity | tonumber),
      "next_steps": $next_steps
    }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  echo "$results_json" > "$RESULTS_JSON"
  exit 0
fi

if [ -z "${SOURCE_VM_RESOURCE_ID//[$'\t\r\n']/}" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Network Watcher probes require SOURCE_VM_RESOURCE_ID" \
    --arg details "Set SOURCE_VM_RESOURCE_ID to the Azure Resource ID of a VM in the target subnet for az network watcher test-connectivity." \
    --arg severity "2" \
    --arg next_steps "Deploy or select a probe VM in the subnet and pass its resource ID. Alternatively set PROBE_MODE=skip-probes for rules-only runs." \
    '. += [{
      "title": $title,
      "details": $details,
      "severity": ($severity | tonumber),
      "next_steps": $next_steps
    }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  echo "$results_json" > "$RESULTS_JSON"
  exit 0
fi

IFS=',' read -ra TARGETS <<< "$PROBE_TARGETS"
if [ "${#TARGETS[@]}" -eq 0 ] || [ -z "${TARGETS[0]//[$'\t\r\n']/}" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "PROBE_TARGETS is empty" \
    --arg details "Provide a comma-separated list of destinations (e.g. https://example.com:443 or host:443)." \
    --arg severity "2" \
    --arg next_steps "Set PROBE_TARGETS to destinations to test from the source VM." \
    '. += [{
      "title": $title,
      "details": $details,
      "severity": ($severity | tonumber),
      "next_steps": $next_steps
    }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  echo "$results_json" > "$RESULTS_JSON"
  exit 0
fi

vm_rg="$AZURE_RESOURCE_GROUP"
if [[ "$SOURCE_VM_RESOURCE_ID" == /subscriptions/* ]]; then
  extracted=$(echo "$SOURCE_VM_RESOURCE_ID" | sed -n 's|.*/resourceGroups/\([^/]*\)/providers/.*|\1|p')
  [ -n "$extracted" ] && vm_rg="$extracted"
fi

for raw in "${TARGETS[@]}"; do
  t=$(echo "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$t" ] && continue

  proto="Tcp"
  host=""
  port="443"

  if [[ "$t" =~ ^https://([^/:]+)(:([0-9]+))? ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[3]:-443}"
    proto="Https"
  elif [[ "$t" =~ ^http://([^/:]+)(:([0-9]+))? ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[3]:-80}"
    proto="Http"
  elif [[ "$t" =~ ^([^:]+):([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
    proto="Tcp"
  else
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Unparseable PROBE target: \`$t\`" \
      --arg details "Use https://host:port, http://host:port, or host:port." \
      --arg severity "2" \
      --arg next_steps "Fix PROBE_TARGETS format and re-run." \
      '. += [{
        "title": $title,
        "details": $details,
        "severity": ($severity | tonumber),
        "next_steps": $next_steps
      }]')
    continue
  fi

  probe_out=""
  if ! probe_out=$(az network watcher test-connectivity \
    --resource-group "$vm_rg" \
    --source-resource "$SOURCE_VM_RESOURCE_ID" \
    --dest-address "$host" \
    --dest-port "$port" \
    --protocol "$proto" \
    --subscription "$AZURE_SUBSCRIPTION_ID" \
    -o json 2>&1); then
    true
  fi

  conn_status=$(echo "$probe_out" | jq -r '.connectionStatus // .properties.connectionStatus // "Unknown"' 2>/dev/null || echo "Unknown")
  if [ "$conn_status" = "Unknown" ]; then
    conn_status=$(echo "$probe_out" | jq -r '.. | .connectionStatus? // empty' | head -1)
    [ -z "$conn_status" ] && conn_status="Failed"
  fi

  snippet=$(echo "$probe_out" | head -c 4000 | jq -Rs .)
  results_json=$(echo "$results_json" | jq \
    --arg target "$t" \
    --arg host "$host" \
    --arg port "$port" \
    --arg proto "$proto" \
    --arg status "$conn_status" \
    --argjson snippet "$snippet" \
    '. += [{
      "target": $target,
      "destinationHost": $host,
      "destinationPort": $port,
      "protocol": $proto,
      "connectionStatus": $status,
      "rawSnippet": $snippet
    }]')

  if [ "$conn_status" != "Reachable" ] && [ "$conn_status" != "Connected" ]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Egress probe failed for \`$t\` (status: $conn_status)" \
      --arg details "Network Watcher test-connectivity from source VM did not report success. Raw output (truncated): $(echo "$probe_out" | head -c 2000)" \
      --arg severity "3" \
      --arg next_steps "Verify NSG egress, UDR, firewall app rules, and that the destination allows the probe. Confirm Network Watcher is available in the region." \
      '. += [{
        "title": $title,
        "details": $details,
        "severity": ($severity | tonumber),
        "next_steps": $next_steps
      }]')
  fi
done

echo "$results_json" > "$RESULTS_JSON"
echo "$issues_json" > "$OUTPUT_FILE"

echo "Probe results:"
echo "$results_json" | jq .
echo "Issues written to $OUTPUT_FILE"
