#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# discover_vms.sh
#
# Lists standalone Compute Engine VMs (instances NOT part of an instance group)
# in the target project and dumps their configuration (name, zone, status,
# machine type, instance id). Serves as the discovery/input for the remaining
# per-VM checks.
#
# Required env: GCP_PROJECT_ID
# Writes      : discovered_vms.json (JSON array of standalone VM objects)
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./gcp_vm_common.sh
. "$SCRIPT_DIR/gcp_vm_common.sh"

VM_LIST=$(discover_standalone_vms)

echo "$VM_LIST" > discovered_vms.json

count=$(jq length discovered_vms.json)
echo "Discovered ${count} standalone compute VMs in project ${GCP_PROJECT_ID}."
jq -r '.[] | "\(.name)\tzone=\(.zone)\tstatus=\(.status)\tmachine_type=\(.machine_type)"' discovered_vms.json
echo "Results saved to discovered_vms.json"
exit 0
