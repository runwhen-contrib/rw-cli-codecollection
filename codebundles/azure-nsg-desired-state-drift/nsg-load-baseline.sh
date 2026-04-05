#!/usr/bin/env bash
# Load baseline NSG definition from file or URL and normalize to export schema.
# Outputs: nsg_baseline_normalized.json, nsg_baseline_issues.json
set -euo pipefail
set -x

: "${BASELINE_PATH:?Must set BASELINE_PATH}"
: "${NSG_NAME:?Must set NSG_NAME}"

BASELINE_FORMAT="${BASELINE_FORMAT:-json-bundle}"
OUT="nsg_baseline_normalized.json"
ISSUES_JSON="nsg_baseline_issues.json"
issues_json='[]'

fetch_input() {
  local path="$1"
  if [[ "$path" =~ ^https?:// ]]; then
    curl -fsSL "$path"
  else
    cat "$path"
  fi
}

load_from_dir() {
  local dir="$1"
  local nsg="$2"
  local f=""
  for candidate in "$dir/${nsg}.json" "$dir/nsg-${nsg}.json" "$dir/${nsg}.normalized.json"; do
    if [ -f "$candidate" ]; then
      f="$candidate"
      break
    fi
  done
  if [ -z "$f" ]; then
    echo ""
    return 1
  fi
  cat "$f"
}

extract_bundle() {
  local raw="$1"
  local nsg="$2"
  if echo "$raw" | jq -e --arg n "$nsg" '.nsgName == $n' >/dev/null 2>&1; then
    echo "$raw" | jq -c .
    return 0
  fi
  if echo "$raw" | jq -e '.nsgs | type == "array"' >/dev/null 2>&1; then
    picked=$(echo "$raw" | jq -c --arg n "$nsg" '.nsgs[]? | select(.nsgName == $n)' | head -1)
    if [ -z "$picked" ]; then return 1; fi
    echo "$picked"
    return 0
  fi
  if echo "$raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
    picked=$(echo "$raw" | jq -c --arg n "$nsg" '.[] | select(.nsgName == $n)' | head -1)
    if [ -z "$picked" ]; then return 1; fi
    echo "$picked"
    return 0
  fi
  echo ""
  return 1
}

RAW=""
case "$BASELINE_FORMAT" in
  per-nsg-dir)
    if ! RAW=$(load_from_dir "$BASELINE_PATH" "$NSG_NAME"); then
      issues_json=$(echo "$issues_json" | jq \
        --arg title "Baseline file not found for NSG \`$NSG_NAME\`" \
        --arg details "Expected ${BASELINE_PATH}/${NSG_NAME}.json (or nsg-${NSG_NAME}.json) in per-nsg-dir mode." \
        --argjson severity 3 \
        --arg next_steps "Add a normalized baseline JSON file for this NSG or fix BASELINE_PATH." \
        '. += [{ "title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps }]')
      echo "$issues_json" > "$ISSUES_JSON"
      echo "null" > "$OUT"
      exit 0
    fi
    ;;
  json-bundle|*)
    if [ ! -f "$BASELINE_PATH" ] && [[ ! "$BASELINE_PATH" =~ ^https?:// ]]; then
      issues_json=$(echo "$issues_json" | jq \
        --arg title "Baseline path not accessible" \
        --arg details "BASELINE_PATH=$BASELINE_PATH is not a file or URL." \
        --argjson severity 3 \
        --arg next_steps "Set BASELINE_PATH to a JSON file, directory (per-nsg-dir), or HTTPS URL." \
        '. += [{ "title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps }]')
      echo "$issues_json" > "$ISSUES_JSON"
      echo "null" > "$OUT"
      exit 0
    fi
    if ! RAW=$(fetch_input "$BASELINE_PATH"); then
      issues_json=$(echo "$issues_json" | jq \
        --arg title "Failed to read baseline from \`$BASELINE_PATH\`" \
        --arg details "Could not read or download baseline content." \
        --argjson severity 3 \
        --arg next_steps "Verify path, permissions, or URL availability." \
        '. += [{ "title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps }]')
      echo "$issues_json" > "$ISSUES_JSON"
      echo "null" > "$OUT"
      exit 0
    fi
    if ! PICKED=$(extract_bundle "$RAW" "$NSG_NAME") || [ -z "$PICKED" ]; then
      issues_json=$(echo "$issues_json" | jq \
        --arg title "NSG \`$NSG_NAME\` not present in baseline bundle" \
        --arg details "Could not find an object with nsgName matching this NSG in the baseline file." \
        --argjson severity 3 \
        --arg next_steps "Ensure baseline JSON includes this NSG under nsgs[] or as a matching object." \
        '. += [{ "title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps }]')
      echo "$issues_json" > "$ISSUES_JSON"
      echo "null" > "$OUT"
      exit 0
    fi
    RAW="$PICKED"
    ;;
esac

# If per-nsg-dir loaded raw file, it may already be normalized
if [ "$BASELINE_FORMAT" = "per-nsg-dir" ]; then
  echo "$RAW" | jq . > "$OUT"
else
  echo "$RAW" | jq . > "$OUT"
fi

echo "$issues_json" | jq . > "$ISSUES_JSON"
echo "Wrote baseline snapshot to $OUT"
