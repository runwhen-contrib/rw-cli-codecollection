*** Settings ***
Documentation       Measures Atlassian organization license health by scoring API reachability, tier headroom, and utilization against configured thresholds. Produces a value between 0 (failing) and 1 (fully passing).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Atlassian Organization License Utilization SLI
Metadata            Supports    Atlassian    Organization    License    Utilization    SaaS
Suite Setup         Suite Initialization

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             Collections


*** Keywords ***
Suite Initialization
    TRY
        ${atlassian_org_api_key}=    RW.Core.Import Secret
        ...    atlassian_org_api_key
        ...    type=string
        ...    description=Organization Admin API key used as Bearer token for Organizations REST API
        ...    pattern=\w*
        Set Suite Variable    ${atlassian_org_api_key}    ${atlassian_org_api_key}
    EXCEPT
        Log    atlassian_org_api_key secret not found    WARN
        Set Suite Variable    ${atlassian_org_api_key}    ${EMPTY}
    END

    ${ATLASSIAN_ORG_ID}=    RW.Core.Import User Variable    ATLASSIAN_ORG_ID
    ...    type=string
    ...    description=Atlassian Cloud organization UUID from Atlassian Administration
    ...    pattern=\w*
    ${ATLASSIAN_ORG_NAME}=    RW.Core.Import User Variable    ATLASSIAN_ORG_NAME
    ...    type=string
    ...    description=Human-readable organization name for reports and task titles
    ...    pattern=.*
    ${ATLASSIAN_DIRECTORY_ID}=    RW.Core.Import User Variable    ATLASSIAN_DIRECTORY_ID
    ...    type=string
    ...    description=Primary user directory ID when the org has multiple directories
    ...    pattern=^[\w-]*$
    ...    default=
    ${LICENSE_UTILIZATION_MIN_PERCENT}=    RW.Core.Import User Variable    LICENSE_UTILIZATION_MIN_PERCENT
    ...    type=string
    ...    description=Minimum acceptable active/billable utilization percentage per product
    ...    pattern=\d+
    ...    default=70
    ${USER_TIER_PROXIMITY_PERCENT}=    RW.Core.Import User Variable    USER_TIER_PROXIMITY_PERCENT
    ...    type=string
    ...    description=Billable-user percentage of purchased tier that triggers proximity alerts
    ...    pattern=\d+
    ...    default=80
    ${INACTIVE_DAYS_THRESHOLD}=    RW.Core.Import User Variable    INACTIVE_DAYS_THRESHOLD
    ...    type=string
    ...    description=Days without product activity before a user is treated as inactive
    ...    pattern=\d+
    ...    default=90
    ${PRODUCTS}=    RW.Core.Import User Variable    PRODUCTS
    ...    type=string
    ...    description=Comma-separated product keys to include or All
    ...    pattern=.*
    ...    default=All
    ${SLI_MAX_USER_PAGES}=    RW.Core.Import User Variable    SLI_MAX_USER_PAGES
    ...    type=string
    ...    description=Maximum managed-account pages fetched during SLI scoring (caps runtime for large orgs)
    ...    pattern=\d+
    ...    default=10

    Set Suite Variable    ${ATLASSIAN_ORG_ID}    ${ATLASSIAN_ORG_ID}
    Set Suite Variable    ${ATLASSIAN_ORG_NAME}    ${ATLASSIAN_ORG_NAME}
    Set Suite Variable    ${ATLASSIAN_DIRECTORY_ID}    ${ATLASSIAN_DIRECTORY_ID}
    Set Suite Variable    ${LICENSE_UTILIZATION_MIN_PERCENT}    ${LICENSE_UTILIZATION_MIN_PERCENT}
    Set Suite Variable    ${USER_TIER_PROXIMITY_PERCENT}    ${USER_TIER_PROXIMITY_PERCENT}
    Set Suite Variable    ${INACTIVE_DAYS_THRESHOLD}    ${INACTIVE_DAYS_THRESHOLD}
    Set Suite Variable    ${PRODUCTS}    ${PRODUCTS}
    Set Suite Variable    ${SLI_MAX_USER_PAGES}    ${SLI_MAX_USER_PAGES}
    Set Suite Variable    ${score_api}    0
    Set Suite Variable    ${score_tier}    0
    Set Suite Variable    ${score_util}    0

    ${env}=    Create Dictionary
    ...    ATLASSIAN_ORG_ID=${ATLASSIAN_ORG_ID}
    ...    ATLASSIAN_ORG_NAME=${ATLASSIAN_ORG_NAME}
    ...    ATLASSIAN_DIRECTORY_ID=${ATLASSIAN_DIRECTORY_ID}
    ...    LICENSE_UTILIZATION_MIN_PERCENT=${LICENSE_UTILIZATION_MIN_PERCENT}
    ...    USER_TIER_PROXIMITY_PERCENT=${USER_TIER_PROXIMITY_PERCENT}
    ...    INACTIVE_DAYS_THRESHOLD=${INACTIVE_DAYS_THRESHOLD}
    ...    PRODUCTS=${PRODUCTS}
    ...    SLI_MAX_USER_PAGES=${SLI_MAX_USER_PAGES}
    Set Suite Variable    ${env}    ${env}


*** Tasks ***
Score Atlassian API Reachability and License Dimensions
    [Documentation]    Runs a lightweight scorer that checks Organizations API auth, tier headroom from workspaces usage/capacity, and utilization against LICENSE_UTILIZATION_MIN_PERCENT.
    [Tags]    Atlassian    sli    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sli-atlassian-org-license-score.sh
    ...    env=${env}
    ...    secret__atlassian_org_api_key=${atlassian_org_api_key}
    ...    timeout_seconds=30
    ...    include_in_history=false
    ...    cmd_override=./sli-atlassian-org-license-score.sh

    TRY
        ${data}=    Evaluate    json.loads(r'''${result.stdout}''')    json
    EXCEPT
        Log    Failed to parse SLI JSON, defaulting to failing scores.    WARN
        ${data}=    Create Dictionary    api_reachable=0    tier_headroom_ok=0    utilization_ok=0
    END

    ${score_api}=    Evaluate    int(${data}.get('api_reachable', 0))
    ${score_tier}=    Evaluate    int(${data}.get('tier_headroom_ok', 0))
    ${score_util}=    Evaluate    int(${data}.get('utilization_ok', 0))
    Set Suite Variable    ${score_api}    ${score_api}
    Set Suite Variable    ${score_tier}    ${score_tier}
    Set Suite Variable    ${score_util}    ${score_util}

    RW.Core.Push Metric    ${score_api}    sub_name=api_reachable
    RW.Core.Push Metric    ${score_tier}    sub_name=tier_headroom_ok
    RW.Core.Push Metric    ${score_util}    sub_name=utilization_ok


Generate Aggregate Atlassian License Health Score
    [Documentation]    Averages API reachability, tier headroom, and utilization sub-scores into the primary 0-1 SLI metric.
    [Tags]    Atlassian    sli    access:read-only    data:metrics

    ${health_score}=    Evaluate    (int(${score_api}) + int(${score_tier}) + int(${score_util})) / 3.0
    ${health_score}=    Convert To Number    ${health_score}    2
    RW.Core.Add To Report    Atlassian license health score for `${ATLASSIAN_ORG_NAME}`: ${health_score} (api=${score_api}, tier=${score_tier}, util=${score_util})
    RW.Core.Push Metric    ${health_score}
