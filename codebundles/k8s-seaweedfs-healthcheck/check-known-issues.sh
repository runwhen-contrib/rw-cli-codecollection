#!/usr/bin/env bash
set -euo pipefail
# Matches installed chart version against curated SeaweedFS known issues.
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

OUTPUT_FILE="known_issues.json"
KNOWN_ISSUES_FILE="${KNOWN_ISSUES_FILE:-seaweedfs-known-issues.json}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source seaweedfs-lib.sh

print_report() {
  echo "=== SeaweedFS known version issues ==="
  echo "  chart_version=$(swf_chart_version)  chart=${SEAWEEDFS_CHART:-$(swf_resolve_chart_label)}"
  jq -r '.[] | "  - [sev=\(.severity)] \(.title)"' "$OUTPUT_FILE" 2>/dev/null || true
}
trap print_report EXIT

catalog="${SCRIPT_DIR}/${KNOWN_ISSUES_FILE}"
if [[ ! -f "$catalog" ]]; then
  swf_add_issue \
    "SeaweedFS known-issues catalog missing" \
    "Expected ${catalog}" \
    4 \
    "Restore seaweedfs-known-issues.json in the codebundle directory."
  swf_write_issues "$OUTPUT_FILE"
  exit 0
fi

version=$(swf_chart_version)
if [[ -z "$version" ]]; then
  swf_add_issue \
    "Unable to determine SeaweedFS chart version in \`${NAMESPACE}\`" \
    "Set SEAWEEDFS_CHART or ensure helm.sh/chart label is present on master StatefulSet." \
    3 \
    "Export SEAWEEDFS_CHART=seaweedfs-X.Y.Z for local runs."
  swf_write_issues "$OUTPUT_FILE"
  exit 0
fi

while IFS= read -r row; do
  [[ -z "$row" ]] && continue
  title=$(echo "$row" | jq -r '.title')
  details=$(echo "$row" | jq -r '.details')
  severity=$(echo "$row" | jq -r '.severity')
  next_steps=$(echo "$row" | jq -r '.next_steps')
  swf_add_issue "$title" "$details" "$severity" "$next_steps"
done < <(jq -c --arg v "$version" '
  def pad(v): (v | split(".") | map(tonumber)) + [0,0,0] | .[0:3];
  .[] | select((pad($v) >= pad(.min_version)) and (pad($v) <= pad(.max_version)))
' "$catalog" 2>/dev/null || true)

swf_write_issues "$OUTPUT_FILE"
