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
#   add_verification_issue - record that a check could not be completed
#   finalize_issues        - guarantee ISSUES_FILE holds a valid JSON array
#   discover_standalone_vms- JSON array of VMs NOT part of an instance group
#   select_target_vms      - JSON array of VMs to check given VM_NAME
#   resolve_target_vms     - select_target_vms + issue on failure/unresolved target
#   resolve_reason         - why the last resolve_target_vms call failed
#   vm_uptime_days         - uptime in (integer) days for a VM object
#
# NOTE ON OUTPUT: everything a check wants an operator to read must go to
# stdout. The task report is built from ${result.stdout} only - RW.CLI keeps
# stderr in a separate field - so a finding announced on stderr never reaches
# the report. Each check therefore prints a line per VM for BOTH outcomes:
# "OK" when a dimension is clean and "ISSUE" when one is raised, so the report
# is legible on its own and does not go quiet exactly when something is wrong.
#
# NOTE: discover_standalone_vms and select_target_vms return non-zero when the
# underlying gcloud calls fail. Callers must not treat that as "no VMs found" -
# use resolve_target_vms, which converts the failure into a reported issue.
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

VM_NAME="${VM_NAME:-All}"
UPTIME_WARNING_DAYS="${UPTIME_WARNING_DAYS:-90}"
PATCH_WARNING_DAYS="${PATCH_WARNING_DAYS:-30}"
DISK_USAGE_THRESHOLD="${DISK_USAGE_THRESHOLD:-85}"

# Accumulator file - each caller sets this before adding issues.
ISSUES_FILE="${ISSUES_FILE:-analysis_output.json}"

# Human-readable reason for the most recent resolve_target_vms failure.
# resolve_target_vms runs inside a command substitution (its stdout IS the VM
# list), so a shell variable would not survive back to the caller and anything
# printed on stdout would corrupt the JSON. The reason goes to this file
# instead, and the caller reads it back with resolve_reason for its report.
RESOLVE_REASON_FILE="${RESOLVE_REASON_FILE:-.resolve_reason}"

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
# -----------------------------------------------------------------------------
# gcloud_reported_failure ERRFILE - true when gcloud signalled a full or partial
# failure on stderr.
#
# `gcloud compute ... list` exits 0 and prints an empty result when the project
# does not exist, an API is disabled, the credential lacks a role, or a zone is
# unreachable - it only writes "WARNING: Some requests did not succeed." to
# stderr. Checking the exit status alone therefore turns any of those into a
# silent "no resources found", which every caller scores as healthy.
# -----------------------------------------------------------------------------
gcloud_reported_failure() {
    local errfile="$1"
    [ -s "$errfile" ] || return 1
    grep -qiE 'some requests did not succeed|was not found|permission denied|does not have permission|has not been used|is not enabled|not authorized|invalid authentication|reauthentication' "$errfile"
}

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
    local instances groups_raw group_members err gname gzone members

    err=$(mktemp)

    # NOTE: failures here are deliberately NOT swallowed. An empty VM list that
    # came from a failed API call is indistinguishable from a genuinely healthy
    # project, so every caller would score 1 ("all clear") during an outage.
    if ! instances=$(gcloud compute instances list \
        --project="$GCP_PROJECT_ID" --format=json 2>"$err") \
        || gcloud_reported_failure "$err"; then
        echo "ERROR: could not list Compute Engine instances in project '${GCP_PROJECT_ID}': $(tr '\n' ' ' <"$err")" >&2
        rm -f "$err"
        return 1
    fi

    if ! groups_raw=$(gcloud compute instance-groups list \
        --project="$GCP_PROJECT_ID" --format="value(name,zone)" 2>"$err") \
        || gcloud_reported_failure "$err"; then
        echo "ERROR: could not list instance groups in project '${GCP_PROJECT_ID}': $(tr '\n' ' ' <"$err")" >&2
        rm -f "$err"
        return 1
    fi

    # Collect "<zone>/<name>" keys of every VM that belongs to an instance group.
    # Zone-qualifying the key stops same-named VMs in different zones colliding.
    group_members=""
    while read -r gname gzone; do
        [ -z "$gname" ] && continue
        gzone="${gzone##*/}"
        if ! members=$(gcloud compute instance-groups list-instances "$gname" \
            --zone="$gzone" --project="$GCP_PROJECT_ID" \
            --format="value(instance)" 2>"$err") \
            || gcloud_reported_failure "$err"; then
            echo "ERROR: could not list members of instance group '${gname}' (zone '${gzone}'): $(tr '\n' ' ' <"$err")" >&2
            rm -f "$err"
            return 1
        fi
        members=$(printf '%s\n' "$members" \
            | sed -E 's#.*/instances/([^/]+)/?$#\1#' \
            | sed -E '/^[[:space:]]*$/d' \
            | sed -E "s#^#${gzone}/#")
        group_members=$(printf '%s\n%s' "$group_members" "$members")
    done <<EOF
$groups_raw
EOF

    rm -f "$err"
    group_members=$(printf '%s' "$group_members" | sed -E '/^[[:space:]]*$/d' | sort -u)

    # Membership is decided from two independent signals:
    #   1. the instance-group listing above (covers unmanaged groups), and
    #   2. the instance's own `created-by` metadata, which a managed instance
    #      group stamps on each member. Signal 2 comes from the SAME snapshot as
    #      the instance list, so a MIG recreating a member mid-run cannot make
    #      that member look standalone.
    echo "$instances" | jq --arg members "$group_members" '
        ([$members | split("\n")[] | select(length > 0)]) as $members_arr |
        [ .[]
          | . as $vm
          | (($vm.zone | split("/") | .[-1]) + "/" + $vm.name) as $key
          | (($vm.metadata.items // [])
              | map(select(.key == "created-by"
                           and ((.value // "") | test("/instanceGroupManagers/"))))
              | length > 0) as $mig_member
          | select((($members_arr | index($key)) | not) and ($mig_member | not))
        ] |
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
# add_verification_issue SCOPE REASON - record that a check could NOT be
# completed. An unverifiable VM is reported as unhealthy on purpose: scoring 1
# here would turn an outage, an expired credential or a revoked role into a
# clean bill of health.
# -----------------------------------------------------------------------------
add_verification_issue() {
    local scope="$1"
    local reason="$2"
    add_issue \
        "Unable to verify ${scope} for Compute VMs in project \`${GCP_PROJECT_ID}\`" \
        "The ${scope} check could not complete for project \`${GCP_PROJECT_ID}\`: ${reason}. The result is UNKNOWN and is reported as unhealthy so that a failed verification is never mistaken for a healthy VM." \
        2 \
        "Confirm the Compute Engine API is enabled for project \`${GCP_PROJECT_ID}\`, that the configured service account credential is valid and unexpired, and that it holds at least roles/compute.viewer; then re-run this check." \
        "The ${scope} check should be able to query the Compute Engine API for project \`${GCP_PROJECT_ID}\`." \
        "The ${scope} check failed to query the Compute Engine API: ${reason}." \
        "{\"issue_type\":\"verification_failed\",\"scope\":\"${scope}\"}"
}

# -----------------------------------------------------------------------------
# resolve_target_vms SCOPE - print the JSON array of VMs to check.
# Returns non-zero (after recording an issue) when the target cannot be
# resolved, i.e. the API calls failed, or a named VM_NAME does not exist as a
# standalone VM in this project.
# -----------------------------------------------------------------------------
resolve_target_vms() {
    local scope="$1"
    local vms count

    rm -f "$RESOLVE_REASON_FILE"

    if ! vms=$(select_target_vms); then
        printf '%s' "the Compute Engine API calls used to enumerate VMs failed (the gcloud error is on stderr)" \
            > "$RESOLVE_REASON_FILE"
        add_verification_issue "$scope" "the Compute Engine API calls used to enumerate VMs failed"
        return 1
    fi

    count=$(printf '%s' "$vms" | jq length)
    if [ "$count" -eq 0 ] && [ "$VM_NAME" != "All" ]; then
        printf '%s' "VM '${VM_NAME}' is not a standalone VM in project ${GCP_PROJECT_ID} - either it no longer exists, or it belongs to an instance group and is out of scope for this CodeBundle" \
            > "$RESOLVE_REASON_FILE"
        add_issue \
            "Compute VM \`${VM_NAME}\` was not found as a standalone VM in project \`${GCP_PROJECT_ID}\`" \
            "VM \`${VM_NAME}\` could not be resolved as a standalone Compute Engine VM in project \`${GCP_PROJECT_ID}\`. Either the VM no longer exists, or it belongs to an instance group and is therefore out of scope for this CodeBundle - its lifecycle is owned by the group. Nothing was checked, so the health of this target is UNKNOWN." \
            3 \
            "Confirm VM \`${VM_NAME}\` still exists with 'gcloud compute instances describe ${VM_NAME} --project=${GCP_PROJECT_ID}'. If it is an instance-group member, monitor it through the owning instance group instead and remove this SLX; if it was deleted, remove this SLX." \
            "VM \`${VM_NAME}\` should exist as a standalone (non instance-group) VM in project \`${GCP_PROJECT_ID}\`." \
            "VM \`${VM_NAME}\` was not found among the standalone VMs of project \`${GCP_PROJECT_ID}\`." \
            "{\"vm\":\"${VM_NAME}\",\"issue_type\":\"target_vm_not_found\"}"
        return 1
    fi

    printf '%s' "$vms"
}

# -----------------------------------------------------------------------------
# resolve_reason - the reason the last resolve_target_vms call failed, for the
# caller to print into its task report. Safe to call unconditionally.
# -----------------------------------------------------------------------------
resolve_reason() {
    if [ -s "$RESOLVE_REASON_FILE" ]; then
        cat "$RESOLVE_REASON_FILE"
    else
        printf '%s' "reason unavailable"
    fi
}

# -----------------------------------------------------------------------------
# select_target_vms - JSON array of VMs to process given VM_NAME.
# When VM_NAME == "All", every standalone VM is selected; otherwise only the
# named VM (if it exists and is standalone).
# -----------------------------------------------------------------------------
select_target_vms() {
    local all_vms
    # Propagate discovery failure instead of degrading to an empty list.
    all_vms=$(discover_standalone_vms) || return 1
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
