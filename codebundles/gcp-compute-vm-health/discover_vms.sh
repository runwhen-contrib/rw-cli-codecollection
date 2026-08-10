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

# Clear any inventory left by a previous run first: if discovery fails below, a
# stale file would let the runbook report the previous run's VMs as current.
rm -f discovered_vms.json

# On failure write an empty inventory rather than dying. Exiting non-zero here
# leaves the calling task with no stdout but still PASSing, so the failure would
# be invisible; an empty inventory makes the runbook raise its "no standalone
# VMs discovered" issue instead.
if ! VM_LIST=$(discover_standalone_vms); then
    echo '[]' > discovered_vms.json
    echo "ERROR: standalone VM discovery FAILED for project ${GCP_PROJECT_ID} (see stderr for the API error)."
    echo "Reporting an empty inventory so this surfaces as a discovery issue instead of reusing stale results."
    exit 0
fi

echo "$VM_LIST" > discovered_vms.json

count=$(jq length discovered_vms.json)
echo "Discovered ${count} standalone compute VMs in project ${GCP_PROJECT_ID}."
jq -r '.[] | "\(.name)\tzone=\(.zone)\tstatus=\(.status)\tmachine_type=\(.machine_type)"' discovered_vms.json
echo "Results saved to discovered_vms.json"
exit 0
