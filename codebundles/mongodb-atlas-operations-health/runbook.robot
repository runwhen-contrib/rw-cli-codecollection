*** Settings ***
Documentation       Read-only MongoDB Atlas project operations posture: open and recent alerts, cloud backup coverage on dedicated clusters, and project IP access patterns that indicate permissive or inconsistent network exposure.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    MongoDB Atlas Operations Health
Metadata            Supports    mongodb_atlas    atlas    alerts    backup    networking    project

Force Tags          mongodb_atlas    atlas    operations    backup    alerts    network    health

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization

*** Tasks ***
Check MongoDB Atlas Open Alerts for Project `${ATLAS_PROJECT_ID}`
    [Documentation]    Queries Atlas Admin API alerts for OPEN and TRACKING conditions (plus recent CLOSED when timestamps parse) scoped by CLUSTER_FILTER and summarizes blast radius for in-scope clusters.
    [Tags]    mongodb_atlas    alerts    access:read-only    data:events

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-atlas-open-alerts.sh
    ...    env=${env}
    ...    secret__atlas_api_key_credentials=${atlas_api_key_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=ATLAS_PROJECT_ID="${ATLAS_PROJECT_ID}" ./check-atlas-open-alerts.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat atlas_open_alerts_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for alerts task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=No unresolved or newly reopened Atlas alerts for scoped clusters without operator acknowledgement
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Atlas open/recent alerts analysis:\n${result.stdout}

Verify MongoDB Atlas Backup Configuration for Project `${ATLAS_PROJECT_ID}`
    [Documentation]    Confirms backupEnabled signals on REPLICA_SET, SHARDED, and GEOSHARDED clusters, treats cloud backup schedule 404 as an unsupported tier hint, and flags clusters lacking backup when the API reports it disabled.
    [Tags]    mongodb_atlas    backup    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=verify-atlas-backup-config.sh
    ...    env=${env}
    ...    secret__atlas_api_key_credentials=${atlas_api_key_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=ATLAS_PROJECT_ID="${ATLAS_PROJECT_ID}" ./verify-atlas-backup-config.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat atlas_backup_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for backup task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Production-typed dedicated clusters should run with Atlas cloud backup / PITR enabled when supported
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Atlas backup configuration review:\n${result.stdout}

Review MongoDB Atlas Network Access for Project `${ATLAS_PROJECT_ID}`
    [Documentation]    Audits project IP access list entries for open CIDRs and correlates an empty list with clusters that still publish public SRV hostnames so risky combinations are visible to operators.
    [Tags]    mongodb_atlas    network    access:read-only    data:security-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=review-atlas-network-access.sh
    ...    env=${env}
    ...    secret__atlas_api_key_credentials=${atlas_api_key_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=ATLAS_PROJECT_ID="${ATLAS_PROJECT_ID}" ./review-atlas-network-access.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat atlas_network_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for network task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Least-privilege network allowlisting or documented private-only connectivity without contradictory public surface area
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Atlas project network access review:\n${result.stdout}

*** Keywords ***
Suite Initialization
    TRY
        ${atlas_api_key_credentials}=    RW.Core.Import Secret    atlas_api_key_credentials
        ...    type=string
        ...    description=MongoDB Atlas API key pair as JSON or KEY=value text with ATLAS_PUBLIC_API_KEY and ATLAS_PRIVATE_API_KEY
        ...    pattern=\w*
        Set Suite Variable    ${atlas_api_key_credentials}    ${atlas_api_key_credentials}
    EXCEPT
        Log    atlas_api_key_credentials secret missing; tasks will surface an auth issue.    WARN
        Set Suite Variable    ${atlas_api_key_credentials}    ${EMPTY}
    END

    ${ATLAS_PROJECT_ID}=    RW.Core.Import User Variable    ATLAS_PROJECT_ID
    ...    type=string
    ...    description=MongoDB Atlas project (group) identifier used in Admin API paths.
    ...    pattern=\w+
    ${ATLAS_ORG_ID}=    RW.Core.Import User Variable    ATLAS_ORG_ID
    ...    type=string
    ...    description=Optional Atlas organization id for discovery context and future org-level checks.
    ...    pattern=^[a-fA-F0-9]*$
    ...    default=
    ${CLUSTER_FILTER}=    RW.Core.Import User Variable    CLUSTER_FILTER
    ...    type=string
    ...    description=Comma-separated cluster names to limit alert, backup, and network correlation scopes.
    ...    pattern=^[\w[:space:],.-]*$
    ...    default=
    ${ALERT_LOOKBACK_HOURS}=    RW.Core.Import User Variable    ALERT_LOOKBACK_HOURS
    ...    type=string
    ...    description=Hours of history to consider when treating recently CLOSED alerts as relevant in the deep-dive task.
    ...    pattern=^\d+$
    ...    default=24

    Set Suite Variable    ${ATLAS_PROJECT_ID}    ${ATLAS_PROJECT_ID}
    Set Suite Variable    ${ATLAS_ORG_ID}    ${ATLAS_ORG_ID}
    Set Suite Variable    ${CLUSTER_FILTER}    ${CLUSTER_FILTER}
    Set Suite Variable    ${ALERT_LOOKBACK_HOURS}    ${ALERT_LOOKBACK_HOURS}

    ${env}=    Create Dictionary
    ...    ATLAS_PROJECT_ID=${ATLAS_PROJECT_ID}
    ...    ATLAS_ORG_ID=${ATLAS_ORG_ID}
    ...    CLUSTER_FILTER=${CLUSTER_FILTER}
    ...    ALERT_LOOKBACK_HOURS=${ALERT_LOOKBACK_HOURS}
    Set Suite Variable    ${env}    ${env}
