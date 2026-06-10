*** Settings ***
Documentation       Measures Atlassian organization license reclamation health by scoring inactive billable users, product overlap waste, stale pending invites, and API reachability. Produces a 0-1 aggregate score where 1 means no severity-3+ reclamation signals.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Atlassian Organization License Optimization SLI
Metadata            Supports    Atlassian    License Optimization    Organization    Cost Management
Force Tags          Atlassian    License Optimization    Organization    SLI

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             Collections

Suite Setup         Suite Initialization


*** Keywords ***
Suite Initialization
    TRY
        ${api_key}=    RW.Core.Import Secret
        ...    atlassian_org_api_key
        ...    type=string
        ...    description=Atlassian Organization Admin API key (Bearer token)
        ...    pattern=\w*
        Set Suite Variable    ${ATLASSIAN_ORG_API_KEY}    ${api_key}
    EXCEPT
        Log    atlassian_org_api_key secret not found.    WARN
        Set Suite Variable    ${ATLASSIAN_ORG_API_KEY}    ${EMPTY}
    END

    ${ATLASSIAN_ORG_ID}=    RW.Core.Import User Variable    ATLASSIAN_ORG_ID
    ...    type=string
    ...    description=Atlassian Cloud organization UUID
    ...    pattern=[\w-]+
    ${ATLASSIAN_ORG_NAME}=    RW.Core.Import User Variable    ATLASSIAN_ORG_NAME
    ...    type=string
    ...    description=Human-readable organization name
    ...    pattern=.*
    ${ATLASSIAN_DIRECTORY_ID}=    RW.Core.Import User Variable    ATLASSIAN_DIRECTORY_ID
    ...    type=string
    ...    description=Primary user directory ID (auto-discover when empty)
    ...    pattern=[\w-]*
    ...    default=
    ${INACTIVE_DAYS_THRESHOLD}=    RW.Core.Import User Variable    INACTIVE_DAYS_THRESHOLD
    ...    type=string
    ...    description=Days without product activity before flagging inactive
    ...    pattern=^\d+$
    ...    default=90
    ${PENDING_INVITE_DAYS_THRESHOLD}=    RW.Core.Import User Variable    PENDING_INVITE_DAYS_THRESHOLD
    ...    type=string
    ...    description=Days before a pending invite is considered stale
    ...    pattern=^\d+$
    ...    default=30
    ${MIN_OVERLAP_PRODUCTS}=    RW.Core.Import User Variable    MIN_OVERLAP_PRODUCTS
    ...    type=string
    ...    description=Minimum licensed products for overlap detection
    ...    pattern=^\d+$
    ...    default=2
    ${RECLAMATION_MIN_SEATS}=    RW.Core.Import User Variable    RECLAMATION_MIN_SEATS
    ...    type=string
    ...    description=Minimum reclaimable seats before SLI sub-score fails
    ...    pattern=^\d+$
    ...    default=5
    ${SLI_MAX_PAGES}=    RW.Core.Import User Variable    SLI_MAX_PAGES
    ...    type=string
    ...    description=Maximum API pages fetched per SLI run for speed
    ...    pattern=^\d+$
    ...    default=2

    Set Suite Variable    ${ATLASSIAN_ORG_ID}    ${ATLASSIAN_ORG_ID}
    Set Suite Variable    ${ATLASSIAN_ORG_NAME}    ${ATLASSIAN_ORG_NAME}
    Set Suite Variable    ${ATLASSIAN_DIRECTORY_ID}    ${ATLASSIAN_DIRECTORY_ID}
    Set Suite Variable    ${INACTIVE_DAYS_THRESHOLD}    ${INACTIVE_DAYS_THRESHOLD}
    Set Suite Variable    ${PENDING_INVITE_DAYS_THRESHOLD}    ${PENDING_INVITE_DAYS_THRESHOLD}
    Set Suite Variable    ${MIN_OVERLAP_PRODUCTS}    ${MIN_OVERLAP_PRODUCTS}
    Set Suite Variable    ${RECLAMATION_MIN_SEATS}    ${RECLAMATION_MIN_SEATS}
    Set Suite Variable    ${SLI_MAX_PAGES}    ${SLI_MAX_PAGES}

    ${env}=    Create Dictionary
    ...    ATLASSIAN_ORG_ID=${ATLASSIAN_ORG_ID}
    ...    ATLASSIAN_ORG_NAME=${ATLASSIAN_ORG_NAME}
    ...    ATLASSIAN_DIRECTORY_ID=${ATLASSIAN_DIRECTORY_ID}
    ...    INACTIVE_DAYS_THRESHOLD=${INACTIVE_DAYS_THRESHOLD}
    ...    PENDING_INVITE_DAYS_THRESHOLD=${PENDING_INVITE_DAYS_THRESHOLD}
    ...    MIN_OVERLAP_PRODUCTS=${MIN_OVERLAP_PRODUCTS}
    ...    RECLAMATION_MIN_SEATS=${RECLAMATION_MIN_SEATS}
    ...    SLI_MAX_PAGES=${SLI_MAX_PAGES}
    Set Suite Variable    ${env}    ${env}

    Set Suite Variable    ${score_inactive}    1
    Set Suite Variable    ${score_overlap}    1
    Set Suite Variable    ${score_invites}    1
    Set Suite Variable    ${score_api}    1


*** Tasks ***
Check Inactive Billable Users and Score
    [Documentation]    Binary score: 1 when inactive billable user count is below RECLAMATION_MIN_SEATS, 0 otherwise.
    [Tags]    Atlassian    sli    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sli-atlassian-license-reclamation-health.sh
    ...    env=${env}
    ...    secret__atlassian_org_api_key=${ATLASSIAN_ORG_API_KEY}
    ...    timeout_seconds=30
    ...    include_in_history=false
    ...    cmd_override=./sli-atlassian-license-reclamation-health.sh

    TRY
        ${data}=    Evaluate    json.loads(r'''${result.stdout}''')    json
        ${score_inactive}=    Evaluate    int(${data}['sub_scores']['inactive_billable'])
        ${score_overlap}=    Evaluate    int(${data}['sub_scores']['product_overlap'])
        ${score_invites}=    Evaluate    int(${data}['sub_scores']['stale_invites'])
        ${score_api}=    Evaluate    int(${data}['sub_scores']['api_reachability'])
        ${health_score}=    Evaluate    float(${data}['health_score'])
        Set Suite Variable    ${score_inactive}
        Set Suite Variable    ${score_overlap}
        Set Suite Variable    ${score_invites}
        Set Suite Variable    ${score_api}
        Set Suite Variable    ${health_score}
        Set Suite Variable    ${sli_counts}    ${data['counts']}
    EXCEPT
        Log    SLI health probe parse failed; defaulting sub-scores to 0.    WARN
        Set Suite Variable    ${score_inactive}    0
        Set Suite Variable    ${score_overlap}    0
        Set Suite Variable    ${score_invites}    0
        Set Suite Variable    ${score_api}    0
        Set Suite Variable    ${health_score}    0
        ${empty}=    Create Dictionary
        Set Suite Variable    ${sli_counts}    ${empty}
    END

    RW.Core.Push Metric    ${score_inactive}    sub_name=inactive_billable
    RW.Core.Push Metric    ${score_overlap}    sub_name=product_overlap
    RW.Core.Push Metric    ${score_invites}    sub_name=stale_invites
    RW.Core.Push Metric    ${score_api}    sub_name=api_reachability

Generate Aggregate License Reclamation Health Score
    [Documentation]    Averages sub-scores into the final 0-1 SLI metric. Healthy when no severity-3+ reclamation signals are present.
    [Tags]    Atlassian    sli    access:read-only    data:config

    ${aggregate}=    Evaluate    (int(${score_inactive}) + int(${score_overlap}) + int(${score_invites}) + int(${score_api})) / 4.0
    ${aggregate}=    Convert To Number    ${aggregate}    2
    RW.Core.Add To Report    Atlassian license reclamation health: ${aggregate} (inactive=${score_inactive}, overlap=${score_overlap}, invites=${score_invites}, api=${score_api})
    RW.Core.Push Metric    ${aggregate}
