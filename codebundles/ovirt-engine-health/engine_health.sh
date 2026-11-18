#!/bin/bash
# Check that the oVirt engine API is reachable and responding with valid data.
# Emits a JSON summary; exits non-zero (with an {"error": ...} object) if the
# token cannot be obtained.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ovirt_auth.sh"

api_json=$(ovirt_get "")

echo "${api_json}" | jq '{
  reachable: (has("product_info") or has("summary")),
  product: (.product_info.name // "oVirt"),
  version: (.product_info.version.full_version // ""),
  vms_total: (.summary.vms.total // null),
  hosts_total: (.summary.hosts.total // null),
  storage_domains_total: (.summary.storage_domains.total // null)
}' 2>/dev/null || echo '{"reachable": false}'
