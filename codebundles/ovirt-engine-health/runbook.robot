*** Settings ***
Documentation       Triage the health of an oVirt virtualization environment via the engine REST API. Inspects
...                 engine reachability, host status, VM status, storage domain capacity, cluster health,
...                 recent critical events, and stale VM snapshots, raising an issue for each problem found.
Metadata            Author    prathamesh
Metadata            Display Name    oVirt Engine Health
Metadata            Supports    oVirt    RHV    OLVM    Virtualization

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             String

Suite Setup         Suite Initialization

*** Tasks ***
Check oVirt Engine `${OVIRT_ENGINE_NAME}` Reachability
    [Documentation]    Verify the oVirt engine API is reachable and an SSO token can be obtained.
    [Tags]    ovirt    engine    health    data:config
    ${rsp}=    RW.CLI.Run Bash File
    ...    bash_file=${CURDIR}/engine_health.sh
    ...    env=${env}
    ...    include_in_history=False
    ...    secret__ovirt_username=${OVIRT_USERNAME}
    ...    secret__ovirt_password=${OVIRT_PASSWORD}
    ...    secret__ovirt_ca_cert=${OVIRT_CA_CERT}
    TRY
        ${data}=    Evaluate    json.loads(r'''${rsp.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty object.    WARN
        ${data}=    Create Dictionary
    END
    ${reachable}=    Set Variable    ${data.get('reachable', False)}
    IF    not ${reachable}
        ${err}=    Set Variable    ${data.get('error', 'Engine API did not return valid data.')}
        RW.Core.Add Issue
        ...    severity=1
        ...    expected=oVirt engine `${OVIRT_ENGINE_NAME}` should be reachable and return valid API data
        ...    actual=oVirt engine `${OVIRT_ENGINE_NAME}` is unreachable or authentication failed
        ...    title=oVirt Engine `${OVIRT_ENGINE_NAME}` Unreachable
        ...    reproduce_hint=Run engine_health.sh against ${OVIRT_ENGINE_URL}
        ...    details=${err}
        ...    next_steps=Verify OVIRT_ENGINE_URL is correct and the engine is running.\nConfirm OVIRT_USERNAME/OVIRT_PASSWORD and the auth profile (e.g. @internal) are valid.\nIf using a self-signed certificate, provide OVIRT_CA_CERT or verify the CA bundle.\nCheck network connectivity and that the ovirt-engine service is up.
    ELSE
        ${product}=    Set Variable    ${data.get('product', 'oVirt')}
        ${version}=    Set Variable    ${data.get('version', 'unknown')}
        RW.Core.Add Pre To Report    oVirt Engine `${OVIRT_ENGINE_NAME}` reachable.\nProduct: ${product}\nVersion: ${version}
    END

Check oVirt Host Status in `${OVIRT_ENGINE_NAME}`
    [Documentation]    Identify hypervisor hosts that are not in a healthy state.
    [Tags]    ovirt    hosts    hypervisor    data:config
    ${rsp}=    RW.CLI.Run Bash File
    ...    bash_file=${CURDIR}/host_status.sh
    ...    env=${env}
    ...    include_in_history=False
    ...    secret__ovirt_username=${OVIRT_USERNAME}
    ...    secret__ovirt_password=${OVIRT_PASSWORD}
    ...    secret__ovirt_ca_cert=${OVIRT_CA_CERT}
    TRY
        ${data}=    Evaluate    json.loads(r'''${rsp.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty object.    WARN
        ${data}=    Create Dictionary
    END
    ${unhealthy}=    Set Variable    ${data.get('unhealthy_hosts', [])}
    IF    len(${unhealthy}) > 0
        ${json_str}=    Evaluate    json.dumps(${unhealthy})    json
        ${table}=    RW.CLI.Run Cli
        ...    cmd=echo '${json_str}' | jq -r '["Host", "Status", "Address"] as $h | $h, (.[] | [.name, .status, .address]) | @tsv' | column -t -s $'\t'
        RW.Core.Add Pre To Report    Unhealthy Hosts:\n=======================================\n${table.stdout}
        FOR    ${host}    IN    @{unhealthy}
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=oVirt host `${host['name']}` should be in the 'up' state
            ...    actual=oVirt host `${host['name']}` is in state `${host['status']}`
            ...    title=oVirt Host `${host['name']}` Not Operational on `${OVIRT_ENGINE_NAME}`
            ...    reproduce_hint=Inspect host `${host['name']}` in the oVirt administration portal
            ...    details=Host: ${host['name']}\nStatus: ${host['status']}\nAddress: ${host['address']}
            ...    next_steps=Open the host in the oVirt portal and review its events.\nCheck connectivity between the engine and the host (VDSM/ovirt-host service).\nFor non_operational hosts, verify required networks and storage domains are attached.\nIf the host is unresponsive, confirm power/management (fencing) and consider reinstalling or re-enrolling.
        END
    ELSE
        RW.Core.Add Pre To Report    No unhealthy oVirt hosts found.
    END

Check oVirt VM Status in `${OVIRT_ENGINE_NAME}`
    [Documentation]    Identify VMs in a paused, unknown, or not-responding state.
    [Tags]    ovirt    vms    data:config
    ${rsp}=    RW.CLI.Run Bash File
    ...    bash_file=${CURDIR}/vm_status.sh
    ...    env=${env}
    ...    include_in_history=False
    ...    secret__ovirt_username=${OVIRT_USERNAME}
    ...    secret__ovirt_password=${OVIRT_PASSWORD}
    ...    secret__ovirt_ca_cert=${OVIRT_CA_CERT}
    TRY
        ${data}=    Evaluate    json.loads(r'''${rsp.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty object.    WARN
        ${data}=    Create Dictionary
    END
    ${problem_vms}=    Set Variable    ${data.get('problem_vms', [])}
    IF    len(${problem_vms}) > 0
        ${json_str}=    Evaluate    json.dumps(${problem_vms})    json
        ${table}=    RW.CLI.Run Cli
        ...    cmd=echo '${json_str}' | jq -r '["VM", "Status"] as $h | $h, (.[] | [.name, .status]) | @tsv' | column -t -s $'\t'
        RW.Core.Add Pre To Report    Problem VMs:\n=======================================\n${table.stdout}
        FOR    ${vm}    IN    @{problem_vms}
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=oVirt VM `${vm['name']}` should be running or cleanly powered off
            ...    actual=oVirt VM `${vm['name']}` is in state `${vm['status']}`
            ...    title=oVirt VM `${vm['name']}` in Problematic State on `${OVIRT_ENGINE_NAME}`
            ...    reproduce_hint=Inspect VM `${vm['name']}` in the oVirt administration portal
            ...    details=VM: ${vm['name']}\nStatus: ${vm['status']}\nHost ID: ${vm['host_id']}
            ...    next_steps=Review the VM's events in the oVirt portal.\nPaused VMs are commonly caused by storage I/O errors - check the underlying storage domain.\nFor 'unknown'/'not_responding' VMs, verify the host running the VM is healthy.\nOnce the underlying issue is resolved, resume or restart the VM.
        END
    ELSE
        RW.Core.Add Pre To Report    No VMs in a problematic state found.
    END

Check oVirt Storage Domain Capacity in `${OVIRT_ENGINE_NAME}`
    [Documentation]    Identify storage domains that are inactive or low on free space.
    [Tags]    ovirt    storage    capacity    data:config
    ${rsp}=    RW.CLI.Run Bash File
    ...    bash_file=${CURDIR}/storage_domains.sh
    ...    cmd_override=${CURDIR}/storage_domains.sh ${OVIRT_STORAGE_FREE_PCT}
    ...    env=${env}
    ...    include_in_history=False
    ...    secret__ovirt_username=${OVIRT_USERNAME}
    ...    secret__ovirt_password=${OVIRT_PASSWORD}
    ...    secret__ovirt_ca_cert=${OVIRT_CA_CERT}
    TRY
        ${data}=    Evaluate    json.loads(r'''${rsp.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty object.    WARN
        ${data}=    Create Dictionary
    END
    ${problem_domains}=    Set Variable    ${data.get('problem_domains', [])}
    IF    len(${problem_domains}) > 0
        ${json_str}=    Evaluate    json.dumps(${problem_domains})    json
        ${table}=    RW.CLI.Run Cli
        ...    cmd=echo '${json_str}' | jq -r '["Domain", "Type", "Status", "Free %"] as $h | $h, (.[] | [.name, .type, .external_status, (.free_pct|tostring)]) | @tsv' | column -t -s $'\t'
        RW.Core.Add Pre To Report    Problem Storage Domains:\n=======================================\n${table.stdout}
        FOR    ${sd}    IN    @{problem_domains}
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=oVirt storage domain `${sd['name']}` should be active with at least ${OVIRT_STORAGE_FREE_PCT}% free
            ...    actual=oVirt storage domain `${sd['name']}` has status `${sd['external_status']}` with ${sd['free_pct']}% free
            ...    title=oVirt Storage Domain `${sd['name']}` Needs Attention on `${OVIRT_ENGINE_NAME}`
            ...    reproduce_hint=Inspect storage domain `${sd['name']}` in the oVirt administration portal
            ...    details=Domain: ${sd['name']}\nType: ${sd['type']}\nExternal status: ${sd['external_status']}\nFree: ${sd['free_pct']}%
            ...    next_steps=If the domain is inactive/in error, reactivate it and check the underlying storage backend connectivity.\nIf free space is low, delete unused disks/snapshots/templates or extend the domain.\nReview storage-related engine events for I/O or connectivity errors.
        END
    ELSE
        RW.Core.Add Pre To Report    All oVirt storage domains are active and above the free-space threshold.
    END

Check oVirt Cluster Health in `${OVIRT_ENGINE_NAME}`
    [Documentation]    Identify clusters with hosts in a non-up, non-maintenance state.
    [Tags]    ovirt    clusters    data:config
    ${rsp}=    RW.CLI.Run Bash File
    ...    bash_file=${CURDIR}/cluster_health.sh
    ...    env=${env}
    ...    include_in_history=False
    ...    secret__ovirt_username=${OVIRT_USERNAME}
    ...    secret__ovirt_password=${OVIRT_PASSWORD}
    ...    secret__ovirt_ca_cert=${OVIRT_CA_CERT}
    TRY
        ${data}=    Evaluate    json.loads(r'''${rsp.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty object.    WARN
        ${data}=    Create Dictionary
    END
    ${problem_clusters}=    Set Variable    ${data.get('problem_clusters', [])}
    IF    len(${problem_clusters}) > 0
        FOR    ${cluster}    IN    @{problem_clusters}
            ${down_names}=    Evaluate    ", ".join(${cluster['down_host_names']})
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=oVirt cluster `${cluster['name']}` should have all hosts up or in maintenance
            ...    actual=oVirt cluster `${cluster['name']}` has ${cluster['down_hosts']} host(s) down
            ...    title=oVirt Cluster `${cluster['name']}` Has Down Hosts on `${OVIRT_ENGINE_NAME}`
            ...    reproduce_hint=Inspect cluster `${cluster['name']}` in the oVirt administration portal
            ...    details=Cluster: ${cluster['name']}\nDown hosts: ${down_names}
            ...    next_steps=Investigate each down host listed above and restore it to service.\nVerify cluster capacity remains sufficient for the running workload.\nCheck for fencing/power-management issues on the affected hosts.
        END
    ELSE
        RW.Core.Add Pre To Report    All oVirt clusters have healthy hosts.
    END

Check oVirt Recent Critical Events in `${OVIRT_ENGINE_NAME}`
    [Documentation]    Surface error/alert severity engine events within the lookback window.
    [Tags]    ovirt    events    data:config
    ${rsp}=    RW.CLI.Run Bash File
    ...    bash_file=${CURDIR}/recent_events.sh
    ...    cmd_override=${CURDIR}/recent_events.sh ${OVIRT_EVENT_LOOKBACK}
    ...    env=${env}
    ...    include_in_history=False
    ...    secret__ovirt_username=${OVIRT_USERNAME}
    ...    secret__ovirt_password=${OVIRT_PASSWORD}
    ...    secret__ovirt_ca_cert=${OVIRT_CA_CERT}
    TRY
        ${data}=    Evaluate    json.loads(r'''${rsp.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty object.    WARN
        ${data}=    Create Dictionary
    END
    ${events}=    Set Variable    ${data.get('critical_events', [])}
    IF    len(${events}) > 0
        ${json_str}=    Evaluate    json.dumps(${events})    json
        ${table}=    RW.CLI.Run Cli
        ...    cmd=echo '${json_str}' | jq -r '["Severity", "Code", "Host", "VM", "Description"] as $h | $h, (.[] | [.severity, (.code|tostring), .host, .vm, .description]) | @tsv' | column -t -s $'\t'
        RW.Core.Add Pre To Report    Critical Events (last ${OVIRT_EVENT_LOOKBACK}):\n=======================================\n${table.stdout}
        ${count}=    Get Length    ${events}
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=No error/alert severity oVirt events in the last ${OVIRT_EVENT_LOOKBACK}
        ...    actual=${count} error/alert oVirt event(s) in the last ${OVIRT_EVENT_LOOKBACK}
        ...    title=oVirt Critical Events Detected on `${OVIRT_ENGINE_NAME}`
        ...    reproduce_hint=Review the Events tab in the oVirt administration portal
        ...    details=${count} critical event(s) found. See the report table for details.
        ...    next_steps=Review each critical event and correlate it with the affected host, VM, or storage domain.\nAddress the root cause indicated by the event descriptions.\nIf events are recurring, investigate the underlying subsystem (storage, networking, fencing).
    ELSE
        RW.Core.Add Pre To Report    No critical oVirt events in the last ${OVIRT_EVENT_LOOKBACK}.
    END

Check oVirt Stale VM Snapshots in `${OVIRT_ENGINE_NAME}`
    [Documentation]    Identify VM snapshots older than the configured maximum age.
    [Tags]    ovirt    snapshots    vms    data:config
    ${rsp}=    RW.CLI.Run Bash File
    ...    bash_file=${CURDIR}/stale_snapshots.sh
    ...    cmd_override=${CURDIR}/stale_snapshots.sh ${OVIRT_SNAPSHOT_MAX_AGE}
    ...    env=${env}
    ...    include_in_history=False
    ...    secret__ovirt_username=${OVIRT_USERNAME}
    ...    secret__ovirt_password=${OVIRT_PASSWORD}
    ...    secret__ovirt_ca_cert=${OVIRT_CA_CERT}
    TRY
        ${data}=    Evaluate    json.loads(r'''${rsp.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty object.    WARN
        ${data}=    Create Dictionary
    END
    ${snapshots}=    Set Variable    ${data.get('stale_snapshots', [])}
    IF    len(${snapshots}) > 0
        ${json_str}=    Evaluate    json.dumps(${snapshots})    json
        ${table}=    RW.CLI.Run Cli
        ...    cmd=echo '${json_str}' | jq -r '["VM", "Snapshot", "Description"] as $h | $h, (.[] | [.vm, .snapshot_id, .description]) | @tsv' | column -t -s $'\t'
        RW.Core.Add Pre To Report    Stale Snapshots (older than ${OVIRT_SNAPSHOT_MAX_AGE}):\n=======================================\n${table.stdout}
        ${count}=    Get Length    ${snapshots}
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=No oVirt VM snapshots older than ${OVIRT_SNAPSHOT_MAX_AGE}
        ...    actual=${count} VM snapshot(s) older than ${OVIRT_SNAPSHOT_MAX_AGE}
        ...    title=Stale oVirt VM Snapshots on `${OVIRT_ENGINE_NAME}`
        ...    reproduce_hint=Review snapshots per VM in the oVirt administration portal
        ...    details=${count} stale snapshot(s) found. See the report table for details.
        ...    next_steps=Review each stale snapshot and confirm it is no longer needed.\nDelete (merge) obsolete snapshots to reclaim space and avoid long merge times.\nConsider a retention policy so snapshots are not left indefinitely.
    ELSE
        RW.Core.Add Pre To Report    No stale VM snapshots older than ${OVIRT_SNAPSHOT_MAX_AGE} found.
    END

*** Keywords ***
Suite Initialization
    ${OVIRT_ENGINE_URL}=    RW.Core.Import User Variable    OVIRT_ENGINE_URL
    ...    type=string
    ...    description=Base URL of your oVirt engine (without the /ovirt-engine path).
    ...    pattern=\w*
    ...    example=https://engine.example.com
    ${OVIRT_USERNAME}=    RW.Core.Import Secret    OVIRT_USERNAME
    ...    type=string
    ...    description=oVirt engine username, including the auth profile.
    ...    pattern=\w*
    ...    example=admin@internal
    ${OVIRT_PASSWORD}=    RW.Core.Import Secret    OVIRT_PASSWORD
    ...    type=string
    ...    description=Password for the oVirt engine user.
    ...    pattern=\w*
    ...    example=changeme
    ${OVIRT_CA_CERT}=    RW.Core.Import Secret    OVIRT_CA_CERT
    ...    type=string
    ...    description=Optional PEM CA bundle to verify the engine TLS certificate. Leave unset to use the system trust store.
    ...    pattern=\w*
    ...    example=-----BEGIN CERTIFICATE-----...
    ...    optional=${True}
    ${OVIRT_STORAGE_FREE_PCT}=    RW.Core.Import User Variable    OVIRT_STORAGE_FREE_PCT
    ...    type=string
    ...    description=Minimum free space percentage per storage domain before it is considered unhealthy.
    ...    pattern=\d+
    ...    example=10
    ...    default=10
    ${OVIRT_EVENT_LOOKBACK}=    RW.Core.Import User Variable    OVIRT_EVENT_LOOKBACK
    ...    type=string
    ...    description=Lookback window for critical events, e.g. 30m, 1h, 1d.
    ...    pattern=\w*
    ...    example=1h
    ...    default=1h
    ${OVIRT_SNAPSHOT_MAX_AGE}=    RW.Core.Import User Variable    OVIRT_SNAPSHOT_MAX_AGE
    ...    type=string
    ...    description=Maximum age before a VM snapshot is considered stale, e.g. 24h, 7d, 2w.
    ...    pattern=\w*
    ...    example=7d
    ...    default=7d
    ${MAX_PAUSED_VMS}=    RW.Core.Import User Variable    MAX_PAUSED_VMS
    ...    type=string
    ...    description=Maximum number of paused/unknown VMs to still consider healthy.
    ...    pattern=\d+
    ...    example=0
    ...    default=0
    ${OVIRT_ENGINE_NAME}=    RW.Core.Import User Variable    OVIRT_ENGINE_NAME
    ...    type=string
    ...    description=A friendly name for this oVirt engine, used in task and report titles.
    ...    pattern=\w*
    ...    example=prod-ovirt
    ...    default=ovirt-engine
    Set Suite Variable    ${env}    {"OVIRT_ENGINE_URL":"${OVIRT_ENGINE_URL}"}
    Set Suite Variable    ${OVIRT_ENGINE_URL}    ${OVIRT_ENGINE_URL}
    Set Suite Variable    ${OVIRT_USERNAME}    ${OVIRT_USERNAME}
    Set Suite Variable    ${OVIRT_PASSWORD}    ${OVIRT_PASSWORD}
    Set Suite Variable    ${OVIRT_CA_CERT}    ${OVIRT_CA_CERT}
    Set Suite Variable    ${OVIRT_STORAGE_FREE_PCT}    ${OVIRT_STORAGE_FREE_PCT}
    Set Suite Variable    ${OVIRT_EVENT_LOOKBACK}    ${OVIRT_EVENT_LOOKBACK}
    Set Suite Variable    ${OVIRT_SNAPSHOT_MAX_AGE}    ${OVIRT_SNAPSHOT_MAX_AGE}
    Set Suite Variable    ${MAX_PAUSED_VMS}    ${MAX_PAUSED_VMS}
    Set Suite Variable    ${OVIRT_ENGINE_NAME}    ${OVIRT_ENGINE_NAME}
