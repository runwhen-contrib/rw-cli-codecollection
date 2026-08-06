*** Settings ***
Documentation       Monitors Atlassian Cloud organization license utilization across entitled products, comparing active versus billable users and proximity to purchased tier limits.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Atlassian Organization License Utilization Report
Metadata            Supports    Atlassian    Organization    License    Utilization    SaaS    FinOps
Force Tags          Atlassian    Organization    License    Utilization    FinOps

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Generate Atlassian License Utilization Report for Organization `${ATLASSIAN_ORG_NAME}`
    [Documentation]    Queries the Atlassian Organizations REST API to build a per-product breakdown of billable users, recently active users, and utilization percentage for finance and IT admin review.
    [Tags]    Atlassian    Organization    Reporting    License    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=generate-atlassian-license-utilization-report.sh
    ...    env=${env}
    ...    secret__atlassian_org_api_key=${atlassian_org_api_key}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./generate-atlassian-license-utilization-report.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat atlassian_utilization_report_issues.json 2>/dev/null || echo "[]"
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for utilization report task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Atlassian organization API should return managed accounts for license reporting
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END


Analyze Billable User Counts Versus Tier Limits for Organization `${ATLASSIAN_ORG_NAME}`
    [Documentation]    Correlates billable user counts with workspace usage/capacity (purchased tier) and flags products at or above the tier-proximity threshold or in overage.
    [Tags]    Atlassian    Organization    Tier    License    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze-atlassian-tier-proximity.sh
    ...    env=${env}
    ...    secret__atlassian_org_api_key=${atlassian_org_api_key}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./analyze-atlassian-tier-proximity.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat atlassian_tier_proximity_issues.json 2>/dev/null || echo "[]"
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for tier proximity task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Billable user counts should remain below purchased tier limits with headroom before renewal
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END


Evaluate License Utilization Thresholds for Organization `${ATLASSIAN_ORG_NAME}`
    [Documentation]    Compares per-product active/billable utilization ratios against LICENSE_UTILIZATION_MIN_PERCENT and emits structured issues with remediation hints.
    [Tags]    Atlassian    Organization    Utilization    License    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=evaluate-atlassian-utilization-thresholds.sh
    ...    env=${env}
    ...    secret__atlassian_org_api_key=${atlassian_org_api_key}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./evaluate-atlassian-utilization-thresholds.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat atlassian_utilization_threshold_issues.json 2>/dev/null || echo "[]"
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for utilization threshold task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Active/billable utilization should meet or exceed ${LICENSE_UTILIZATION_MIN_PERCENT}% per monitored product
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END


Report Active User Trends Across Atlassian Products for Organization `${ATLASSIAN_ORG_NAME}`
    [Documentation]    Summarizes unique active users per product using last_active timestamps and highlights products with declining active-user share versus billable seats.
    [Tags]    Atlassian    Organization    Trends    License    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=report-atlassian-active-user-trends.sh
    ...    env=${env}
    ...    secret__atlassian_org_api_key=${atlassian_org_api_key}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./report-atlassian-active-user-trends.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat atlassian_active_trend_issues.json 2>/dev/null || echo "[]"
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for active user trends task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Active user share should remain stable relative to billable seats across entitled products
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END


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
    ...    description=Primary user directory ID when the org has multiple directories (default: discover first directory)
    ...    pattern=^[\w-]*$
    ...    default=
    ${LICENSE_UTILIZATION_MIN_PERCENT}=    RW.Core.Import User Variable    LICENSE_UTILIZATION_MIN_PERCENT
    ...    type=string
    ...    description=Minimum acceptable active/billable utilization percentage per product before raising an issue
    ...    pattern=\d+
    ...    default=70
    ${USER_TIER_PROXIMITY_PERCENT}=    RW.Core.Import User Variable    USER_TIER_PROXIMITY_PERCENT
    ...    type=string
    ...    description=Billable-user count as a percentage of purchased tier that triggers proximity alerts
    ...    pattern=\d+
    ...    default=80
    ${INACTIVE_DAYS_THRESHOLD}=    RW.Core.Import User Variable    INACTIVE_DAYS_THRESHOLD
    ...    type=string
    ...    description=Days without product activity before a user is treated as inactive for utilization math
    ...    pattern=\d+
    ...    default=90
    ${PRODUCTS}=    RW.Core.Import User Variable    PRODUCTS
    ...    type=string
    ...    description=Comma-separated product keys to include (e.g. jira-software,confluence,loom) or All
    ...    pattern=.*
    ...    default=All
    ${TIMEOUT_SECONDS}=    RW.Core.Import User Variable    TIMEOUT_SECONDS
    ...    type=string
    ...    description=Per-task timeout; orgs with large user bases may need higher values
    ...    pattern=\d+
    ...    default=600

    Set Suite Variable    ${ATLASSIAN_ORG_ID}    ${ATLASSIAN_ORG_ID}
    Set Suite Variable    ${ATLASSIAN_ORG_NAME}    ${ATLASSIAN_ORG_NAME}
    Set Suite Variable    ${ATLASSIAN_DIRECTORY_ID}    ${ATLASSIAN_DIRECTORY_ID}
    Set Suite Variable    ${LICENSE_UTILIZATION_MIN_PERCENT}    ${LICENSE_UTILIZATION_MIN_PERCENT}
    Set Suite Variable    ${USER_TIER_PROXIMITY_PERCENT}    ${USER_TIER_PROXIMITY_PERCENT}
    Set Suite Variable    ${INACTIVE_DAYS_THRESHOLD}    ${INACTIVE_DAYS_THRESHOLD}
    Set Suite Variable    ${PRODUCTS}    ${PRODUCTS}
    Set Suite Variable    ${TIMEOUT_SECONDS}    ${TIMEOUT_SECONDS}

    ${env}=    Create Dictionary
    ...    ATLASSIAN_ORG_ID=${ATLASSIAN_ORG_ID}
    ...    ATLASSIAN_ORG_NAME=${ATLASSIAN_ORG_NAME}
    ...    ATLASSIAN_DIRECTORY_ID=${ATLASSIAN_DIRECTORY_ID}
    ...    LICENSE_UTILIZATION_MIN_PERCENT=${LICENSE_UTILIZATION_MIN_PERCENT}
    ...    USER_TIER_PROXIMITY_PERCENT=${USER_TIER_PROXIMITY_PERCENT}
    ...    INACTIVE_DAYS_THRESHOLD=${INACTIVE_DAYS_THRESHOLD}
    ...    PRODUCTS=${PRODUCTS}
    Set Suite Variable    ${env}    ${env}
