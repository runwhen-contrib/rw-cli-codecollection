#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_SUBSCRIPTION_ID
#   PROBE_TARGETS (comma-separated host:port or URLs)
#
# OPTIONAL:
#   PROBE_MODE   network-watcher | bastion-agent | skip-probes
#   SOURCE_VM_RESOURCE_ID
#   AZURE_RESOURCE_GROUP  (for network watcher location lookup)
#   VNET_NAME
#
# Outputs: subnet_probe_issues.json
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
: "${PROBE_TARGETS:?Must set PROBE_TARGETS}"

OUTPUT_ISSUES="subnet_probe_issues.json"
issues_json='[]'
MODE=${PROBE_MODE:-network-watcher}
SOURCE_VM=${SOURCE_VM_RESOURCE_ID:-}

az account set --subscription "${AZURE_SUBSCRIPTION_ID}" >/dev/null 2>&1 || true

if [[ "$MODE" == "skip-probes" ]]; then
  echo "$issues_json" > "$OUTPUT_ISSUES"
  echo "PROBE_MODE=skip-probes: no connectivity probes executed (rules-only)."
  exit 0
fi

if [[ "$MODE" == "bastion-agent" ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Bastion-Agent Probe Mode Not Automated Here" \
    --arg details "PROBE_MODE=bastion-agent requires manual or agent-based probes from inside the subnet. Automated az CLI probes were skipped." \
    --arg severity "2" \
    --arg next_steps "Run curl/HTTPS probes from a jump host or automation agent in the subnet, or switch PROBE_MODE to network-watcher with SOURCE_VM_RESOURCE_ID." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
  echo "$issues_json" > "$OUTPUT_ISSUES"
  exit 0
fi

# network-watcher mode
if [[ -z "$SOURCE_VM" ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Network Watcher Probes Require SOURCE_VM_RESOURCE_ID" \
    --arg details "PROBE_MODE=network-watcher but SOURCE_VM_RESOURCE_ID is empty; connection troubleshoot needs a source VM resource ID in the target subnet." \
    --arg severity "3" \
    --arg next_steps "Set SOURCE_VM_RESOURCE_ID to a VM in the subnet, use PROBE_MODE=skip-probes for rules-only validation, or use bastion-agent with manual probes." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
  echo "$issues_json" > "$OUTPUT_ISSUES"
  exit 0
fi

# Resolve location from VM
if ! vm_json=$(az vm show --ids "$SOURCE_VM" -o json 2>err_vm.log); then
  err_msg=$(cat err_vm.log 2>/dev/null || echo "error")
  rm -f err_vm.log
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot Resolve Source VM for Probes" \
    --arg details "az vm show failed for $SOURCE_VM: $err_msg" \
    --arg severity "4" \
    --arg next_steps "Verify SOURCE_VM_RESOURCE_ID is a valid VM resource ID and credentials can read it." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
  echo "$issues_json" > "$OUTPUT_ISSUES"
  exit 0
fi
rm -f err_vm.log

LOCATION=$(echo "$vm_json" | jq -r '.location')

parse_target() {
  local t="$1"
  t="${t//[[:space:]]/}"
  if [[ "$t" =~ ^https?:// ]]; then
    local rest="${t#*://}"
    local hostport="${rest%%/*}"
    if [[ "$hostport" == *:* ]]; then
      echo "${hostport%%:*}" "${hostport##*:}"
    else
      if [[ "$t" =~ ^https:// ]]; then echo "$hostport" 443; else echo "$hostport" 80; fi
    fi
  elif [[ "$t" == *:* ]]; then
    echo "${t%%:*}" "${t##*:}"
  else
    echo "$t" 443
  fi
}

IFS=',' read -ra TARGS <<< "${PROBE_TARGETS}"
for raw in "${TARGS[@]}"; do
  tgt=$(echo "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [[ -z "$tgt" ]] && continue
  read -r dest_host dest_port < <(parse_target "$tgt")

  probe_json="{}"
  if ! probe_json=$(az network watcher connection-test \
    --location "$LOCATION" \
    --source-resource-id "$SOURCE_VM" \
    --dest-address "$dest_host" \
    --dest-port "$dest_port" \
    -o json 2>err_probe.log); then
    err_msg=$(cat err_probe.log 2>/dev/null || echo "error")
    rm -f err_probe.log
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Network Watcher Probe Failed for \`${dest_host}:${dest_port}\`" \
      --arg details "connection-test CLI error: $err_msg" \
      --arg severity "3" \
      --arg next_steps "Ensure Network Watcher is enabled in region $LOCATION and your principal has Network Contributor (or least-privilege equivalent)." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": ($severity | tonumber),
         "next_steps": $next_steps
       }]')
    continue
  fi
  rm -f err_probe.log

  conn_status=$(echo "$probe_json" | jq -r '.connectionStatus // "Unknown"')
  if [[ "$conn_status" != "Reachable" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Egress Probe Not Reachable: \`${dest_host}:${dest_port}\`" \
      --arg details "connectionStatus=$conn_status from VM. Full response: $(echo "$probe_json" | jq -c .)" \
      --arg severity "3" \
      --arg next_steps "Review NSG, route table, Azure Firewall application rules, and any NVA for this path; confirm DNS and private endpoints if applicable." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": ($severity | tonumber),
         "next_steps": $next_steps
       }]')
  fi
done

echo "$issues_json" > "$OUTPUT_ISSUES"
echo "Probe results written to $OUTPUT_ISSUES"
