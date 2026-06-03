*** Settings ***
Documentation       Measures the health of an oVirt virtualization environment via the engine REST API:
...                 engine reachability, host status, VM status, storage domain capacity, cluster health,
...                 recent critical events, and stale VM snapshots. Pushes a composite 0-1 health score.
Metadata            Author    prathamesh
Metadata            Display Name    oVirt Engine Health
Metadata            Supports    oVirt    RHV    OLVM    Virtualization

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

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
    ${engine_score}=    Evaluate    1 if ${reachable} else 0
    Set Global Variable    ${engine_score}
    RW.Core.Push Metric    ${engine_score}    sub_name=engine_reachable

Check oVirt Host Status in `${OVIRT_ENGINE_NAME}`
    [Documentation]    Score 1 when no hypervisor hosts are in an unhealthy (non-operational) state.
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
    ${host_score}=    Evaluate    1 if len($unhealthy) == 0 else 0
    Set Global Variable    ${host_score}
    RW.Core.Push Metric    ${host_score}    sub_name=host_status

Check oVirt VM Status in `${OVIRT_ENGINE_NAME}`
    [Documentation]    Score 1 when paused/unknown/not-responding VMs are within the allowed maximum.
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
    ${vm_score}=    Evaluate    1 if len($problem_vms) <= int(${MAX_PAUSED_VMS}) else 0
    Set Global Variable    ${vm_score}
    RW.Core.Push Metric    ${vm_score}    sub_name=vm_status

Check oVirt Storage Domain Capacity in `${OVIRT_ENGINE_NAME}`
    [Documentation]    Score 1 when all storage domains are active and above the free-space threshold.
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
    ${storage_score}=    Evaluate    1 if len($problem_domains) == 0 else 0
    Set Global Variable    ${storage_score}
    RW.Core.Push Metric    ${storage_score}    sub_name=storage_capacity

Check oVirt Cluster Health in `${OVIRT_ENGINE_NAME}`
    [Documentation]    Score 1 when no cluster has hosts in a non-up, non-maintenance state.
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
    ${cluster_score}=    Evaluate    1 if len($problem_clusters) == 0 else 0
    Set Global Variable    ${cluster_score}
    RW.Core.Push Metric    ${cluster_score}    sub_name=cluster_health

Check oVirt Recent Critical Events in `${OVIRT_ENGINE_NAME}`
    [Documentation]    Score 1 when there are no error/alert severity events in the lookback window.
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
    ${events_score}=    Evaluate    1 if len($events) == 0 else 0
    Set Global Variable    ${events_score}
    RW.Core.Push Metric    ${events_score}    sub_name=critical_events

Check oVirt Stale VM Snapshots in `${OVIRT_ENGINE_NAME}`
    [Documentation]    Score 1 when there are no VM snapshots older than the configured maximum age.
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
    ${snapshot_score}=    Evaluate    1 if len($snapshots) == 0 else 0
    Set Global Variable    ${snapshot_score}
    RW.Core.Push Metric    ${snapshot_score}    sub_name=stale_snapshots

Generate oVirt Engine `${OVIRT_ENGINE_NAME}` Health Score
    [Documentation]    Average the individual check scores into a composite health score.
    ${health_score}=    Evaluate    (${engine_score} + ${host_score} + ${vm_score} + ${storage_score} + ${cluster_score} + ${events_score} + ${snapshot_score}) / 7
    ${health_score}=    Convert To Number    ${health_score}    2
    RW.Core.Push Metric    ${health_score}

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
