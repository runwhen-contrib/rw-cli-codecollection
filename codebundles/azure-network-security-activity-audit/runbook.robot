*** Settings ***
Documentation       Audits Azure Activity Log for NSG and Azure Firewall mutations and classifies callers against CI/CD allowlists for governance review.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Azure NSG and Firewall Change Activity Audit
Metadata            Supports    Azure    NSG    Firewall    Activity Log    Governance

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Force Tags          Azure    NSG    Firewall    ActivityLog    Governance

Suite Setup         Suite Initialization


*** Tasks ***
Query Activity Log for NSG Mutations in Subscription `${AZURE_SUBSCRIPTION_ID}`
    [Documentation]    Lists write, delete, and action operations on network security groups and rules in the lookback window and flags query failures or high volume.
    [Tags]    Azure    NSG    ActivityLog    access:read-only    data:logs-bulk
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=activity-log-nsg-writes.sh
    ...    env=${env}
    ...    timeout_seconds=240
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=ACTIVITY_LOOKBACK_HOURS=${ACTIVITY_LOOKBACK_HOURS} ./activity-log-nsg-writes.sh

    ${issues}=    RW.CLI.Run Cli    cmd=cat nsg_issues.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for NSG task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=NSG-related activity log operations should succeed and remain within expected change volume
            ...    actual=Activity log findings for NSG mutations in subscription `${AZURE_SUBSCRIPTION_ID}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    NSG activity audit:\n${result.stdout}

Query Activity Log for Azure Firewall and Policy Mutations in Subscription `${AZURE_SUBSCRIPTION_ID}`
    [Documentation]    Lists write operations on Azure Firewall, firewall policies, and related rule collections in the lookback window.
    [Tags]    Azure    Firewall    ActivityLog    access:read-only    data:logs-bulk
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=activity-log-firewall-writes.sh
    ...    env=${env}
    ...    timeout_seconds=240
    ...    include_in_history=false
    ...    cmd_override=./activity-log-firewall-writes.sh

    ${issues}=    RW.CLI.Run Cli    cmd=cat firewall_issues.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for firewall task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Firewall and policy activity log operations should succeed under normal conditions
            ...    actual=Activity log findings for firewall or policy mutations in subscription `${AZURE_SUBSCRIPTION_ID}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Firewall activity audit:\n${result.stdout}

Classify Callers Against Allowlist for Subscription `${AZURE_SUBSCRIPTION_ID}`
    [Documentation]    Tags mutation events as automated versus manual or unknown using CICD_APP_IDS and CICD_OBJECT_IDS when configured.
    [Tags]    Azure    Classification    access:read-only    data:logs-bulk
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=activity-classify-callers.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=./activity-classify-callers.sh

    ${issues}=    RW.CLI.Run Cli    cmd=cat classify_issues.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for classify task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Automation identities should match configured allowlists when classifying callers
            ...    actual=Classification results for network security mutations in subscription `${AZURE_SUBSCRIPTION_ID}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Caller classification:\n${result.stdout}

Flag Manual or Out-of-Band Changes for Subscription `${AZURE_SUBSCRIPTION_ID}`
    [Documentation]    Raises issues for non-allowlisted identities and for changes outside optional UTC maintenance hours.
    [Tags]    Azure    Governance    access:read-only    data:logs-bulk
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=activity-flag-manual-changes.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=./activity-flag-manual-changes.sh

    ${issues}=    RW.CLI.Run Cli    cmd=cat flag_issues.json

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
            ...    expected=Changes should come from allowlisted automation or occur inside the maintenance window when configured
            ...    actual=Governance findings for subscription `${AZURE_SUBSCRIPTION_ID}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Manual change flags:\n${result.stdout}

Summarize Change Timeline and Top Actors for Subscription `${AZURE_SUBSCRIPTION_ID}`
    [Documentation]    Aggregates counts by operation and caller and provides an Activity Log portal link for the subscription.
    [Tags]    Azure    Summary    access:read-only    data:logs-bulk
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=activity-summary-report.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=./activity-summary-report.sh

    ${issues}=    RW.CLI.Run Cli    cmd=cat summary_issues.json

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
            ...    expected=Operators should have a clear summary of mutation activity for governance review
            ...    actual=Summary output for subscription `${AZURE_SUBSCRIPTION_ID}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Summary report:\n${result.stdout}


*** Keywords ***
Suite Initialization
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=JSON with AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET; Reader on subscription for Activity Log
    ...    pattern=\w*
    ${AZURE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=Azure subscription ID to audit.
    ...    pattern=\w*
    ${AZURE_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZURE_RESOURCE_GROUP
    ...    type=string
    ...    description=Optional resource group scope; leave empty for entire subscription.
    ...    pattern=\w*
    ...    default=${EMPTY}
    ${ACTIVITY_LOOKBACK_HOURS}=    RW.Core.Import User Variable    ACTIVITY_LOOKBACK_HOURS
    ...    type=string
    ...    description=Hours of Activity Log history to query.
    ...    pattern=\w*
    ...    default=168
    ${CICD_APP_IDS}=    RW.Core.Import User Variable    CICD_APP_IDS
    ...    type=string
    ...    description=Comma-separated Azure AD application (client) IDs approved for automation.
    ...    pattern=\w*
    ...    default=${EMPTY}
    ${CICD_OBJECT_IDS}=    RW.Core.Import User Variable    CICD_OBJECT_IDS
    ...    type=string
    ...    description=Comma-separated object IDs for managed identities or service principals.
    ...    pattern=\w*
    ...    default=${EMPTY}
    ${MAINTENANCE_START_HOUR_UTC}=    RW.Core.Import User Variable    MAINTENANCE_START_HOUR_UTC
    ...    type=string
    ...    description=Optional maintenance window start hour (0-23 UTC) for flagging out-of-window changes.
    ...    pattern=\w*
    ...    default=${EMPTY}
    ${MAINTENANCE_END_HOUR_UTC}=    RW.Core.Import User Variable    MAINTENANCE_END_HOUR_UTC
    ...    type=string
    ...    description=Optional maintenance window end hour (0-23 UTC), exclusive when start less than end.
    ...    pattern=\w*
    ...    default=${EMPTY}
    ${AZURE_TENANT_ID}=    RW.Core.Import User Variable    AZURE_TENANT_ID
    ...    type=string
    ...    description=Optional tenant ID for portal context in summary output.
    ...    pattern=\w*
    ...    default=${EMPTY}

    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${ACTIVITY_LOOKBACK_HOURS}    ${ACTIVITY_LOOKBACK_HOURS}
    Set Suite Variable    ${CICD_APP_IDS}    ${CICD_APP_IDS}
    Set Suite Variable    ${CICD_OBJECT_IDS}    ${CICD_OBJECT_IDS}
    Set Suite Variable    ${MAINTENANCE_START_HOUR_UTC}    ${MAINTENANCE_START_HOUR_UTC}
    Set Suite Variable    ${MAINTENANCE_END_HOUR_UTC}    ${MAINTENANCE_END_HOUR_UTC}
    Set Suite Variable    ${AZURE_TENANT_ID}    ${AZURE_TENANT_ID}

    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}", "AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "ACTIVITY_LOOKBACK_HOURS":"${ACTIVITY_LOOKBACK_HOURS}", "CICD_APP_IDS":"${CICD_APP_IDS}", "CICD_OBJECT_IDS":"${CICD_OBJECT_IDS}", "MAINTENANCE_START_HOUR_UTC":"${MAINTENANCE_START_HOUR_UTC}", "MAINTENANCE_END_HOUR_UTC":"${MAINTENANCE_END_HOUR_UTC}", "AZURE_TENANT_ID":"${AZURE_TENANT_ID}"}

    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZURE_SUBSCRIPTION_ID}
    ...    include_in_history=false
