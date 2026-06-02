*** Settings ***
Documentation       Cheap Azure DevOps organization-health SLI. Averages THREE binary {0,1} availability sub-scores from lightweight, time-sensitive org signals — no active platform incident, pool capacity OK (queue-derived, ephemeral scaled-to-zero excluded), and required org security policy present — into a primary health score between 0 (failing) and 1 (healthy). A fourth signal, license_headroom_ok, is pushed as an informational sub-metric only (license saturation is a cost/procurement concern, not an availability incident, so it does not drive the SLO). Intended to run hourly; the heavy license cost / inactive-user / cross-project scans stay in the daily deep runbook. Its SLO breach triggers this SLX's organization runbook.
Metadata            Author    runwhen
Metadata            Display Name    Azure DevOps Organization Health SLI
Metadata            Supports    AzureDevOps    Organization    Health    SLI

Library             String
Library             BuiltIn
Library             Collections
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Score Azure DevOps Organization Health for `${AZURE_DEVOPS_ORG}`
    [Documentation]    Runs the lightweight org scorer and pushes the sub-scores: platform_incident_ok, pool_capacity_ok (queue-derived, bounded), and org_policy_ok (these three drive the composite), plus license_headroom_ok (single userentitlementsummary call) as an informational-only sub-metric. Convention is "score 0 only for what we measure and confirm bad, 1 for what we cannot measure".
    [Tags]    Organization    AzureDevOps    sli    access:read-only    data:metrics
    ${score_env}=    Create Dictionary
    ...    AZURE_DEVOPS_ORG=${AZURE_DEVOPS_ORG}
    ...    LICENSE_UTILIZATION_THRESHOLD=${LICENSE_UTILIZATION_THRESHOLD}
    ...    QUEUE_AGING_THRESHOLD_MIN=${QUEUE_AGING_THRESHOLD_MIN}
    ...    ORG_POOL_PROBE_LIMIT=${ORG_POOL_PROBE_LIMIT}
    ...    AGENT_FETCH_PARALLELISM=${AGENT_FETCH_PARALLELISM}
    ...    AUTH_TYPE=${AUTH_TYPE}
    ...    AZURE_CONFIG_DIR=${AZURE_DEVOPS_CONFIG_DIR}

    ${data}=    Create Dictionary
    ...    platform_incident_ok=1    pool_capacity_ok=1
    ...    license_headroom_ok=1    org_policy_ok=1    details=${{ {} }}
    TRY
        ${out}=    RW.CLI.Run Bash File
        ...    bash_file=sli-org-health-score.sh
        ...    env=${score_env}
        ...    secret__azure_devops_pat=${AZURE_DEVOPS_PAT}
        ...    timeout_seconds=180
        ...    include_in_history=false
        ${data}=    Evaluate    json.loads(r'''${out.stdout}''')    json
    EXCEPT    AS    ${err}
        Log    Organization SLI scoring failed: ${err}    WARN
    END

    ${platform_ok}=    Set Variable    ${data.get('platform_incident_ok', 1)}
    ${pool_ok}=    Set Variable    ${data.get('pool_capacity_ok', 1)}
    ${license_ok}=    Set Variable    ${data.get('license_headroom_ok', 1)}
    ${policy_ok}=    Set Variable    ${data.get('org_policy_ok', 1)}

    Set Suite Variable    ${score_platform}    ${platform_ok}
    Set Suite Variable    ${score_pool}    ${pool_ok}
    Set Suite Variable    ${score_license}    ${license_ok}
    Set Suite Variable    ${score_policy}    ${policy_ok}

    RW.Core.Push Metric    ${platform_ok}    sub_name=platform_incident_ok
    RW.Core.Push Metric    ${pool_ok}    sub_name=pool_capacity_ok
    RW.Core.Push Metric    ${license_ok}    sub_name=license_headroom_ok
    RW.Core.Push Metric    ${policy_ok}    sub_name=org_policy_ok

    ${d}=    Evaluate    ${data}.get('details', {})    json
    ${ctx}=    Set Variable    Org `${AZURE_DEVOPS_ORG}` SLI: platform_status=${d.get('incident_health', '-')} (${d.get('incident_message', '-')}), pools_probed=${d.get('pools_probed', '-')} (aging_queue=${d.get('pools_with_aging_queue', '-')}), license_max_util=${d.get('license_max_utilization_pct', '-')}% (${d.get('license_headroom_detail', '-')}, threshold ${d.get('license_utilization_threshold_pct', '-')}%), admin_groups=${d.get('admin_security_groups', '-')}
    RW.Core.Add To Report    ${ctx}

Generate Aggregate Azure DevOps Organization Health Score for `${AZURE_DEVOPS_ORG}`
    [Documentation]    Averages the three AVAILABILITY sub-scores (platform_incident_ok, pool_capacity_ok, org_policy_ok) into the primary SLI metric. license_headroom_ok is pushed as an informational sub-metric only and is intentionally EXCLUDED from the health score: license saturation is a cost/procurement concern (e.g. 149/149 seats assigned) that would otherwise hold the SLI red indefinitely without indicating any availability impact. License capacity is tracked in the daily deep runbook instead. A breach of this SLI's SLO triggers this SLX's deep organization runbook.
    [Tags]    Organization    AzureDevOps    sli    access:read-only    data:metrics
    ${total}=    Evaluate    int(${score_platform}) + int(${score_pool}) + int(${score_policy})
    ${health_score}=    Evaluate    ${total} / 3.0
    ${health_score}=    Convert To Number    ${health_score}    2
    ${report_msg}=    Set Variable    Azure DevOps organization health score: ${health_score} (platform_incident_ok=${score_platform}, pool_capacity_ok=${score_pool}, org_policy_ok=${score_policy}; informational: license_headroom_ok=${score_license})
    RW.Core.Add To Report    ${report_msg}
    RW.Core.Push Metric    ${health_score}


*** Keywords ***
Suite Initialization
    Log    Starting Organization SLI Suite Initialization...    INFO

    # Support both Azure Service Principal and Azure DevOps PAT authentication
    TRY
        ${azure_credentials}=    RW.Core.Import Secret
        ...    azure_credentials
        ...    type=string
        ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
        ...    pattern=\w*
        Set Suite Variable    ${AUTH_TYPE}    service_principal
        Set Suite Variable    ${AZURE_DEVOPS_PAT}    ${EMPTY}
    EXCEPT
        Log    Azure credentials not found, trying Azure DevOps PAT...    INFO
        TRY
            ${azure_devops_pat}=    RW.Core.Import Secret
            ...    azure_devops_pat
            ...    type=string
            ...    description=Azure DevOps Personal Access Token
            ...    pattern=\w*
            Set Suite Variable    ${AUTH_TYPE}    pat
            Set Suite Variable    ${AZURE_DEVOPS_PAT}    ${azure_devops_pat}
        EXCEPT
            Log    No authentication method found, defaulting to service principal...    WARN
            Set Suite Variable    ${AUTH_TYPE}    service_principal
            Set Suite Variable    ${AZURE_DEVOPS_PAT}    ${EMPTY}
        END
    END

    ${AZURE_DEVOPS_ORG}=    RW.Core.Import User Variable    AZURE_DEVOPS_ORG
    ...    type=string
    ...    description=Azure DevOps organization name.
    ...    pattern=\w*
    ${LICENSE_UTILIZATION_THRESHOLD}=    RW.Core.Import User Variable    LICENSE_UTILIZATION_THRESHOLD
    ...    type=string
    ...    description=License utilization (assigned/total) percentage above which license_headroom_ok drops to 0, for any billed license whose total is measurable. Stakeholder/unlimited entries are skipped (cannot measure = healthy).
    ...    default=90
    ...    pattern=\w*
    ${QUEUE_AGING_THRESHOLD_MIN}=    RW.Core.Import User Variable    QUEUE_AGING_THRESHOLD_MIN
    ...    type=string
    ...    description=Minutes a build (notStarted job request) may wait in a self-hosted pool's queue before pool_capacity_ok drops to 0. A scaled-to-zero elastic/ephemeral pool with no aging queue is not penalised.
    ...    default=30
    ...    pattern=^\d+$
    ${ORG_POOL_PROBE_LIMIT}=    RW.Core.Import User Variable    ORG_POOL_PROBE_LIMIT
    ...    type=string
    ...    description=Maximum number of self-hosted pools whose job-request queue is probed per SLI run. Bounds the hourly probe so it stays cheap on organizations with hundreds of pools (the deep daily runbook covers the rest).
    ...    default=150
    ...    pattern=^\d+$
    ${AGENT_FETCH_PARALLELISM}=    RW.Core.Import User Variable    AGENT_FETCH_PARALLELISM
    ...    type=string
    ...    description=Parallelism for the bounded job-request queue probe. Clamped to 1-32.
    ...    default=20
    ...    pattern=^\d+$

    Set Suite Variable    ${AZURE_DEVOPS_ORG}    ${AZURE_DEVOPS_ORG}
    Set Suite Variable    ${LICENSE_UTILIZATION_THRESHOLD}    ${LICENSE_UTILIZATION_THRESHOLD}
    Set Suite Variable    ${QUEUE_AGING_THRESHOLD_MIN}    ${QUEUE_AGING_THRESHOLD_MIN}
    Set Suite Variable    ${ORG_POOL_PROBE_LIMIT}    ${ORG_POOL_PROBE_LIMIT}
    Set Suite Variable    ${AGENT_FETCH_PARALLELISM}    ${AGENT_FETCH_PARALLELISM}
    Set Suite Variable    ${AZURE_DEVOPS_CONFIG_DIR}    %{CODEBUNDLE_TEMP_DIR}/.azure-devops

    Log    Organization SLI Suite Initialization complete (org=${AZURE_DEVOPS_ORG}).    INFO
