*** Settings ***
Documentation       Queries Azure Activity Log for create, update, and delete operations on Network Security Groups, Azure Firewall, and firewall policies; classifies callers against CI/CD allowlists and summarizes change activity for governance review.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Azure NSG and Firewall Change Activity Audit
Metadata            Supports    Azure    NSG    Firewall    Activity Log    Governance    Audit
Force Tags          Azure    NSG    Firewall    Activity Log    Governance    Audit

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Query Activity Log for NSG Write Operations in Subscription `${AZURE_SUBSCRIPTION_ID}`
    [Documentation]    Lists write, delete, and action operations on Network Security Groups and NSG rules in the configured lookback window; captures caller, claims, HTTP status, and correlation IDs for governance review.
    [Tags]    Azure    NSG    Activity Log    access:read-only    data:logs-bulk

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=activity-log-nsg-writes.sh
    ...    env=${env}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=ACTIVITY_LOOKBACK_HOURS=${ACTIVITY_LOOKBACK_HOURS} ./activity-log-nsg-writes.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat nsg_writes_issues.json 2>/dev/null || echo "[]"
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for NSG activity task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Activity log query should succeed and surface NSG mutations without query failures
            ...    actual=Anomaly or query issue detected while listing NSG-related mutations
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    NSG activity query output:
    RW.Core.Add Pre To Report    ${result.stdout}


Query Activity Log for Azure Firewall and Policy Write Operations in Subscription `${AZURE_SUBSCRIPTION_ID}`
    [Documentation]    Lists write, delete, and action operations on Azure Firewall, firewall policies, and rule collections in the lookback window for correlation with NSG changes.
    [Tags]    Azure    Firewall    Activity Log    access:read-only    data:logs-bulk

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=activity-log-firewall-writes.sh
    ...    env=${env}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    cmd_override=ACTIVITY_LOOKBACK_HOURS=${ACTIVITY_LOOKBACK_HOURS} ./activity-log-firewall-writes.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat firewall_writes_issues.json 2>/dev/null || echo "[]"
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for firewall activity task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Activity log query should succeed for Azure Firewall and policy resources
            ...    actual=Query failure or failed operations detected for firewall-related mutations
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Firewall / policy activity query output:
    RW.Core.Add Pre To Report    ${result.stdout}


Classify Activity Log Callers Against CI/CD Allowlist for Subscription `${AZURE_SUBSCRIPTION_ID}`
    [Documentation]    Merges NSG and firewall mutation events and labels each as automated (matches allowlist), manual/suspect, or unknown based on appId and objectId claims.
    [Tags]    Azure    NSG    Firewall    Classification    access:read-only    data:logs-bulk

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=activity-classify-callers.sh
    ...    env=${env}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    cmd_override=./activity-classify-callers.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat classify_issues.json 2>/dev/null || echo "[]"
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for classification task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Callers should map to approved automation identities when allowlists are configured
            ...    actual=Non-allowlisted or unknown caller patterns detected in the activity window
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Caller classification output:
    RW.Core.Add Pre To Report    ${result.stdout}


Flag Manual or Out-of-Band Network Security Changes for Subscription `${AZURE_SUBSCRIPTION_ID}`
    [Documentation]    Raises issues for mutations that do not match the CI/CD allowlist when configured, and for changes outside optional UTC maintenance hours.
    [Tags]    Azure    NSG    Firewall    Governance    access:read-only    data:logs-bulk

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=activity-flag-manual-changes.sh
    ...    env=${env}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    cmd_override=./activity-flag-manual-changes.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat flag_manual_issues.json 2>/dev/null || echo "[]"
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for flag task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Changes should originate from approved automation or fall inside maintenance windows
            ...    actual=Manual or out-of-window network security mutations detected
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Manual / out-of-band flag output:
    RW.Core.Add Pre To Report    ${result.stdout}


Summarize Network Security Change Timeline and Top Actors for Subscription `${AZURE_SUBSCRIPTION_ID}`
    [Documentation]    Aggregates counts by caller and operation name and prints a portal link to subscription Activity Log for deeper review.
    [Tags]    Azure    NSG    Firewall    Reporting    access:read-only    data:logs-bulk

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=activity-summary-report.sh
    ...    env=${env}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    cmd_override=./activity-summary-report.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat summary_issues.json 2>/dev/null || echo "[]"
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for summary task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Summary should complete without structural errors
            ...    actual=Summary task reported an informational issue
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Summary report:
    RW.Core.Add Pre To Report    ${result.stdout}


*** Keywords ***
Suite Initialization
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=JSON or env-style secret with AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET for Azure CLI
    ...    pattern=\w*

    ${AZURE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=Azure subscription ID to audit
    ...    pattern=[a-fA-F0-9-]+

    ${AZURE_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZURE_RESOURCE_GROUP
    ...    type=string
    ...    description=Optional resource group name to scope activity queries; leave empty for entire subscription
    ...    pattern=.*
    ...    default=""

    ${ACTIVITY_LOOKBACK_HOURS}=    RW.Core.Import User Variable    ACTIVITY_LOOKBACK_HOURS
    ...    type=string
    ...    description=Hours of activity log history to analyze
    ...    pattern=\d+
    ...    default=168

    ${CICD_APP_IDS}=    RW.Core.Import User Variable    CICD_APP_IDS
    ...    type=string
    ...    description=Comma-separated Azure AD application (client) IDs approved for automation
    ...    pattern=.*
    ...    default=""

    ${CICD_OBJECT_IDS}=    RW.Core.Import User Variable    CICD_OBJECT_IDS
    ...    type=string
    ...    description=Comma-separated object IDs for managed identities or service principals
    ...    pattern=.*
    ...    default=""

    ${ACTIVITY_LOG_MAX_EVENTS}=    RW.Core.Import User Variable    ACTIVITY_LOG_MAX_EVENTS
    ...    type=string
    ...    description=Maximum events returned per activity-log query (Azure CLI default is 50)
    ...    pattern=\d+
    ...    default=500

    ${MAINTENANCE_START_HOUR_UTC}=    RW.Core.Import User Variable    MAINTENANCE_START_HOUR_UTC
    ...    type=string
    ...    description=Optional start hour (0-23 UTC) for maintenance window; pair with MAINTENANCE_END_HOUR_UTC
    ...    pattern=\d*
    ...    default=""

    ${MAINTENANCE_END_HOUR_UTC}=    RW.Core.Import User Variable    MAINTENANCE_END_HOUR_UTC
    ...    type=string
    ...    description=Optional end hour (0-23 UTC) for maintenance window
    ...    pattern=\d*
    ...    default=""

    ${TIMEOUT_SECONDS}=    RW.Core.Import User Variable    TIMEOUT_SECONDS
    ...    type=string
    ...    description=Timeout for bash tasks in seconds
    ...    pattern=\d+
    ...    default=240

    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${ACTIVITY_LOOKBACK_HOURS}    ${ACTIVITY_LOOKBACK_HOURS}
    Set Suite Variable    ${CICD_APP_IDS}    ${CICD_APP_IDS}
    Set Suite Variable    ${CICD_OBJECT_IDS}    ${CICD_OBJECT_IDS}
    Set Suite Variable    ${ACTIVITY_LOG_MAX_EVENTS}    ${ACTIVITY_LOG_MAX_EVENTS}
    Set Suite Variable    ${MAINTENANCE_START_HOUR_UTC}    ${MAINTENANCE_START_HOUR_UTC}
    Set Suite Variable    ${MAINTENANCE_END_HOUR_UTC}    ${MAINTENANCE_END_HOUR_UTC}
    Set Suite Variable    ${TIMEOUT_SECONDS}    ${TIMEOUT_SECONDS}

    ${env}=    Create Dictionary
    ...    AZURE_SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}
    ...    AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP}
    ...    ACTIVITY_LOOKBACK_HOURS=${ACTIVITY_LOOKBACK_HOURS}
    ...    CICD_APP_IDS=${CICD_APP_IDS}
    ...    CICD_OBJECT_IDS=${CICD_OBJECT_IDS}
    ...    ACTIVITY_LOG_MAX_EVENTS=${ACTIVITY_LOG_MAX_EVENTS}
    ...    MAINTENANCE_START_HOUR_UTC=${MAINTENANCE_START_HOUR_UTC}
    ...    MAINTENANCE_END_HOUR_UTC=${MAINTENANCE_END_HOUR_UTC}
    Set Suite Variable    ${env}    ${env}

    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZURE_SUBSCRIPTION_ID}
    ...    include_in_history=false
