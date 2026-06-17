#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Loads and normalizes baseline NSG definition from BASELINE_PATH (file or directory).
# BASELINE_FORMAT: json-bundle | per-nsg-dir
# Output: nsg_baseline_bundle.json, nsg_baseline_issues.json
# -----------------------------------------------------------------------------

: "${BASELINE_PATH:?Must set BASELINE_PATH}"
OUTPUT_BUNDLE="nsg_baseline_bundle.json"
OUTPUT_ISSUES="nsg_baseline_issues.json"
issues_json='[]'
FORMAT="${BASELINE_FORMAT:-json-bundle}"

normalize_nsg() {
  jq '
    def fr($r):
      ($r.properties // $r) as $p
      | {
          name: ($r.name // ""),
          priority: ($p.priority // 0),
          direction: ($p.direction // ""),
          access: ($p.access // ""),
          protocol: ($p.protocol // ""),
          sourcePortRange: ($p.sourcePortRange // ""),
          destinationPortRange: ($p.destinationPortRange // ""),
          sourceAddressPrefix: ($p.sourceAddressPrefix // ""),
          destinationAddressPrefix: ($p.destinationAddressPrefix // ""),
          sourceAddressPrefixes: ($p.sourceAddressPrefixes // [] | sort),
          destinationAddressPrefixes: ($p.destinationAddressPrefixes // [] | sort),
          sourcePortRanges: ($p.sourcePortRanges // [] | sort),
          destinationPortRanges: ($p.destinationPortRanges // [] | sort),
          description: ($p.description // "")
        };
    {
      schemaVersion: "1",
      subscriptionId: (if (.id|type) == "string" and (.id|length) > 0 then (.id|split("/")[2]) else (.subscriptionId // "") end),
      resourceGroup: (.resourceGroup // (try (.id | capture("/resourceGroups/(?<g>[^/]+)/") | .g) catch "")),
      name: (.name // ""),
      id: (.id // ""),
      securityRules: ((.securityRules // []) | map(fr(.)) | sort_by(.priority, .name)),
      defaultSecurityRules: ((.defaultSecurityRules // []) | map(fr(.)) | sort_by(.priority, .name))
    }
  '
}

merged='[]'

if [ ! -e "$BASELINE_PATH" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg t "Baseline Path Not Found" \
    --arg d "BASELINE_PATH=$BASELINE_PATH does not exist" \
    --arg n "Set BASELINE_PATH to a checked-in export or Terraform JSON artifact." \
    --argjson sev 4 \
    '. += [{"title": $t, "details": $d, "severity": $sev, "next_steps": $n}]')
  echo "$issues_json" > "$OUTPUT_ISSUES"
  echo '{"schemaVersion":"1","subscriptionId":"","label":"baseline","nsgs":[]}' > "$OUTPUT_BUNDLE"
  exit 0
fi

add_nsg_json() {
  local blob="$1"
  local norm
  norm=$(echo "$blob" | normalize_nsg) || return 1
  merged=$(echo "$merged" | jq --argjson x "$norm" '. += [$x]')
}

if [ "$FORMAT" = "per-nsg-dir" ] && [ -d "$BASELINE_PATH" ]; then
  shopt -s nullglob
  for f in "$BASELINE_PATH"/*.json; do
    if ! add_nsg_json "$(cat "$f")"; then
      issues_json=$(echo "$issues_json" | jq \
        --arg t "Invalid Baseline File" \
        --arg d "Could not parse $f" \
        --arg n "Fix JSON or use json-bundle format." \
        --argjson sev 3 \
        '. += [{"title": $t, "details": $d, "severity": $sev, "next_steps": $n}]')
    fi
  done
  shopt -u nullglob
elif [ -f "$BASELINE_PATH" ]; then
  raw=$(cat "$BASELINE_PATH")
  if echo "$raw" | jq -e '.nsgs | type == "array"' >/dev/null 2>&1; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      if ! add_nsg_json "$line"; then
        issues_json=$(echo "$issues_json" | jq \
          --arg t "Invalid Baseline NSG Entry" \
          --arg d "An entry in .nsgs could not be normalized" \
          --arg n "Ensure each entry matches az network nsg show JSON shape." \
          --argjson sev 3 \
          '. += [{"title": $t, "details": $d, "severity": $sev, "next_steps": $n}]')
      fi
    done < <(echo "$raw" | jq -c '.nsgs[]')
  else
    if ! add_nsg_json "$raw"; then
      issues_json=$(echo "$issues_json" | jq \
        --arg t "Invalid Baseline Bundle" \
        --arg d "Expected .nsgs array or single NSG object in $BASELINE_PATH" \
        --arg n "Export with nsg-export-live-rules.sh or provide json-bundle." \
        --argjson sev 4 \
        '. += [{"title": $t, "details": $d, "severity": $sev, "next_steps": $n}]')
    fi
  fi
else
  issues_json=$(echo "$issues_json" | jq \
    --arg t "Unsupported Baseline Path" \
    --arg d "BASELINE_PATH must be a file or directory for format=$FORMAT" \
    --arg n "Use json-bundle file or per-nsg-dir directory of JSON files." \
    --argjson sev 3 \
    '. += [{"title": $t, "details": $d, "severity": $sev, "next_steps": $n}]')
fi

bundle=$(jq -n \
  --argjson nsgs "$merged" \
  --arg lbl "baseline" \
  '{schemaVersion: "1", subscriptionId: "", label: $lbl, nsgs: $nsgs}')
echo "$bundle" | jq '.' > "$OUTPUT_BUNDLE"
echo "$issues_json" | jq '.' > "$OUTPUT_ISSUES"
echo "Loaded $(echo "$bundle" | jq '.nsgs | length') baseline NSG(s)"
