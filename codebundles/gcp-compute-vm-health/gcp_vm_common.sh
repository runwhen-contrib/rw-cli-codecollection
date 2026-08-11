#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# gcp_vm_common.sh - Shared helpers for the gcp-compute-vm-health CodeBundle.
#
# Required env:
#   GCP_PROJECT_ID   - GCP project ID hosting the VMs (required)
#
# Optional env (with defaults):
#   VM_NAME               - single standalone VM name, or "All" to scan every
#                           standalone VM in the project  (default: All)
#   UPTIME_WARNING_DAYS   - days a VM may run before a reboot is encouraged
#   PATCH_WARNING_DAYS    - days a missing/pending patch may go unremediated
#   DISK_USAGE_THRESHOLD  - percent full above which a disk is flagged
#
# Provided functions:
#   add_issue              - append an issue object to the current ISSUES_FILE
#   finalize_issues        - guarantee ISSUES_FILE holds a valid JSON array
#   discover_standalone_vms- JSON array of VMs NOT part of an instance group
#   select_target_vms      - JSON array of VMs to check given VM_NAME
#   vm_uptime_days         - uptime in (integer) days for a VM object
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

VM_NAME="${VM_NAME:-All}"
UPTIME_WARNING_DAYS="${UPTIME_WARNING_DAYS:-90}"
PATCH_WARNING_DAYS="${PATCH_WARNING_DAYS:-30}"
DISK_USAGE_THRESHOLD="${DISK_USAGE_THRESHOLD:-85}"

# Accumulator file - each caller sets this before adding issues.
ISSUES_FILE="${ISSUES_FILE:-analysis_output.json}"

# Access token fetched lazily and reused across OS Config API calls.
_GCP_ACCESS_TOKEN=""

# -----------------------------------------------------------------------------
# add_issue TITLE DETAILS SEVERITY NEXT_STEPS EXPECTED ACTUAL [JSON_EXTRA]
# Appends one issue object to ISSUES_FILE (created as '[]' on first write).
# -----------------------------------------------------------------------------
add_issue() {
    local title="$1"
    local details="$2"
    local severity="$3"
    local next_steps="$4"
    local expected="$5"
    local actual="$6"
    local json_extra="$7"
    if [ -z "$json_extra" ]; then
        json_extra="{}"
    fi

    if [ ! -f "$ISSUES_FILE" ]; then
        echo '[]' > "$ISSUES_FILE"
    fi

    local entry
    entry=$(jq -n \
        --arg title "$title" \
        --arg details "$details" \
        --arg severity "$severity" \
        --arg next_steps "$next_steps" \
        --arg expected "$expected" \
        --arg actual "$actual" \
        '{title:$title, details:$details, severity:($severity|tonumber), next_steps:$next_steps, expected:$expected, actual:$actual}')
    entry=$(printf '%s\n%s' "$entry" "$json_extra" | jq -s '.[0] * .[1]')
    jq -c --argjson e "$entry" '. += [$e]' "$ISSUES_FILE" > "${ISSUES_FILE}.tmp" && mv "${ISSUES_FILE}.tmp" "$ISSUES_FILE"
}

# -----------------------------------------------------------------------------
# finalize_issues - write a valid '[]' to ISSUES_FILE if no issues were added.
# -----------------------------------------------------------------------------
finalize_issues() {
    if [ ! -f "$ISSUES_FILE" ]; then
        echo '[]' > "$ISSUES_FILE"
    fi
}

# -----------------------------------------------------------------------------
# gcp_access_token - print a current OAuth2 access token (cached).
# -----------------------------------------------------------------------------
gcp_access_token() {
    if [ -z "$_GCP_ACCESS_TOKEN" ]; then
        _GCP_ACCESS_TOKEN=$(gcloud auth print-access-token 2>/dev/null || echo "")
    fi
    printf '%s' "$_GCP_ACCESS_TOKEN"
}

# -----------------------------------------------------------------------------
# discover_standalone_vms - JSON array of VMs in the project that are NOT
# members of any managed or unmanaged instance group.
#
# Fields: name, zone, status, instance_id, machine_type, last_start_timestamp
# -----------------------------------------------------------------------------
discover_standalone_vms() {
    local instances group_members

    instances=$(gcloud compute instances list \
        --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")

    # Collect the short names of every VM that is a member of an instance group.
    group_members=$(gcloud compute instance-groups list \
        --project="$GCP_PROJECT_ID" --format="value(name,zone)" 2>/dev/null | \
        while read -r gname gzone; do
            [ -z "$gname" ] && continue
            gcloud compute instance-groups list-instances "$gname" \
                --zone="$gzone" --project="$GCP_PROJECT_ID" \
                --format="value(instance)" 2>/dev/null
        done | sed -E 's#.*/instances/([^/]+)/?$#\1#' | sort -u)

    echo "$instances" | jq --arg members "$group_members" '
        [$members | split("\n")[]] as $members_arr |
        [.[] | . as $vm | select([$members_arr[] | . == $vm.name] | any | not)] |
        map({
            name: .name,
            zone: (.zone | split("/") | .[-1]),
            status: .status,
            instance_id: .id,
            machine_type: (.machineType | split("/") | .[-1]),
            last_start_timestamp: (.lastStartTimestamp // .creationTimestamp)
        })'
}

# -----------------------------------------------------------------------------
# select_target_vms - JSON array of VMs to process given VM_NAME.
# When VM_NAME == "All", every standalone VM is selected; otherwise only the
# named VM (if it exists and is standalone).
# -----------------------------------------------------------------------------
select_target_vms() {
    local all_vms
    all_vms=$(discover_standalone_vms)
    if [ "$VM_NAME" = "All" ]; then
        printf '%s' "$all_vms"
    else
        printf '%s' "$all_vms" | jq --arg vm "$VM_NAME" '[.[] | select(.name == $vm)]'
    fi
}

# -----------------------------------------------------------------------------
# vm_uptime_days OBJ - integer days since the VM last started (0 when unknown).
# -----------------------------------------------------------------------------
vm_uptime_days() {
    local obj="$1"
    local last_start now_epoch start_epoch
    last_start=$(printf '%s' "$obj" | jq -r '.last_start_timestamp // empty')
    if [ -z "$last_start" ] || [ "$last_start" = "null" ]; then
        printf '0'
        return
    fi
    now_epoch=$(date -u +%s)
    start_epoch=$(date -u -d "$last_start" +%s 2>/dev/null || printf '%s' "$now_epoch")
    printf '%s' "$(( (now_epoch - start_epoch) / 86400 ))"
}

# -----------------------------------------------------------------------------
# uptime_object OBJ - JSON object of { uptime_days, last_start_timestamp } for
# use as the extra field on an issue.
# -----------------------------------------------------------------------------
uptime_object() {
    local obj="$1"
    printf '%s' "$obj" | jq '{ uptime_days: (.last_start_timestamp | if . == null then 0 else ((now - (fromdateiso8601 // now)) / 86400 | floor) end) }' 2>/dev/null \
        || printf '{"uptime_days": 0}'
}
