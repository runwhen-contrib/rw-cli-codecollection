*** Settings ***
Documentation       Identifies Atlassian Cloud license waste and rightsizing opportunities across inactive billable users, overlapping product entitlements, and stale pending invites, then produces prioritized reclamation recommendations.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Atlassian Organization License Optimization
Metadata            Supports    Atlassian    License Optimization    Organization    Cost Management
Force Tags          Atlassian    License Optimization    Organization    Cost Management

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Identify Inactive Billable Users Across Atlassian Products for Organization `${ATLASSIAN_ORG_NAME}`
    [Documentation]    Pages managed accounts and enriches with per-product last_active dates to flag billable users without recent activity within INACTIVE_DAYS_THRESHOLD.
    [Tags]    Atlassian    Organization    License Optimization    Inactive Users    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=identify-atlassian-inactive-billable-users.sh
    ...    env=${env}
    ...    secret__atlassian_org_api_key=${ATLASSIAN_ORG_API_KEY}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./identify-atlassian-inactive-billable-users.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat atlassian_inactive_billable_issues.json 2>/dev/null || echo "[]"
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for inactive billable users task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Billable users in organization `${ATLASSIAN_ORG_NAME}` should show product activity within `${INACTIVE_DAYS_THRESHOLD}` days
            ...    actual=Inactive billable users detected without recent product activity
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Inactive Billable Users Analysis:
    RW.Core.Add Pre To Report    ${result.stdout}

Analyze Overlapping Product Entitlements for Organization `${ATLASSIAN_ORG_NAME}`
    [Documentation]    Finds users licensed on multiple products who are active on only a subset, highlighting redundant seat assignments under per-product or Teamwork Collection licensing.
    [Tags]    Atlassian    Organization    License Optimization    Product Overlap    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze-atlassian-product-overlap.sh
    ...    env=${env}
    ...    secret__atlassian_org_api_key=${ATLASSIAN_ORG_API_KEY}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./analyze-atlassian-product-overlap.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat atlassian_product_overlap_issues.json 2>/dev/null || echo "[]"
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for product overlap task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Users in organization `${ATLASSIAN_ORG_NAME}` should use all licensed products they are assigned
            ...    actual=Users with overlapping product entitlements are inactive on one or more licensed products
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Product Overlap Analysis:
    RW.Core.Add Pre To Report    ${result.stdout}

Surface Pending Invites and Unaccepted Seats for Organization `${ATLASSIAN_ORG_NAME}`
    [Documentation]    Detects invited-but-not-accepted users and pending product access that still count toward user tier limits, quantifying reclaimable seats from stale invites.
    [Tags]    Atlassian    Organization    License Optimization    Pending Invites    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=surface-atlassian-pending-invites.sh
    ...    env=${env}
    ...    secret__atlassian_org_api_key=${ATLASSIAN_ORG_API_KEY}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./surface-atlassian-pending-invites.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat atlassian_pending_invite_issues.json 2>/dev/null || echo "[]"
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for pending invites task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Pending invitations in organization `${ATLASSIAN_ORG_NAME}` should be accepted or revoked within `${PENDING_INVITE_DAYS_THRESHOLD}` days
            ...    actual=Stale or outstanding pending invites are consuming license capacity
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Pending Invites Analysis:
    RW.Core.Add Pre To Report    ${result.stdout}

Recommend License Reclamation Actions for Organization `${ATLASSIAN_ORG_NAME}`
    [Documentation]    Synthesizes findings from prior tasks into prioritized suspend, remove, and consolidate recommendations with estimated seat savings and a markdown report for IT/finance handoff.
    [Tags]    Atlassian    Organization    License Optimization    Recommendations    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=recommend-atlassian-license-reclamation.sh
    ...    env=${env}
    ...    secret__atlassian_org_api_key=${ATLASSIAN_ORG_API_KEY}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./recommend-atlassian-license-reclamation.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat atlassian_reclamation_issues.json 2>/dev/null || echo "[]"
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for reclamation recommendations task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=License utilization in organization `${ATLASSIAN_ORG_NAME}` should minimize reclaimable seat waste before renewal
            ...    actual=Prioritized license reclamation opportunities identified with estimated seat savings
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    ${report}=    RW.CLI.Run Cli
    ...    cmd=cat atlassian_license_reclamation_report.md 2>/dev/null || echo "(report not generated)"
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false

    RW.Core.Add Pre To Report    License Reclamation Report:
    RW.Core.Add Pre To Report    ${report.stdout}
    RW.Core.Add Pre To Report    ${result.stdout}


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
    ...    description=Human-readable organization name for reports and task titles
    ...    pattern=.*
    ${ATLASSIAN_DIRECTORY_ID}=    RW.Core.Import User Variable    ATLASSIAN_DIRECTORY_ID
    ...    type=string
    ...    description=Primary user directory ID (auto-discover when empty)
    ...    pattern=[\w-]*
    ...    default=
    ${INACTIVE_DAYS_THRESHOLD}=    RW.Core.Import User Variable    INACTIVE_DAYS_THRESHOLD
    ...    type=string
    ...    description=Days without product activity before flagging a billable user as inactive
    ...    pattern=^\d+$
    ...    default=90
    ${PENDING_INVITE_DAYS_THRESHOLD}=    RW.Core.Import User Variable    PENDING_INVITE_DAYS_THRESHOLD
    ...    type=string
    ...    description=Days an outstanding invite may sit before it is flagged as stale
    ...    pattern=^\d+$
    ...    default=30
    ${MIN_OVERLAP_PRODUCTS}=    RW.Core.Import User Variable    MIN_OVERLAP_PRODUCTS
    ...    type=string
    ...    description=Minimum licensed products before overlap analysis applies to a user
    ...    pattern=^\d+$
    ...    default=2
    ${PRODUCTS}=    RW.Core.Import User Variable    PRODUCTS
    ...    type=string
    ...    description=Comma-separated product keys to analyze or All
    ...    pattern=.*
    ...    default=All
    ${RECLAMATION_MIN_SEATS}=    RW.Core.Import User Variable    RECLAMATION_MIN_SEATS
    ...    type=string
    ...    description=Minimum reclaimable seats per product before emitting a recommendation issue
    ...    pattern=^\d+$
    ...    default=5
    ${TIMEOUT_SECONDS}=    RW.Core.Import User Variable    TIMEOUT_SECONDS
    ...    type=string
    ...    description=Per-task timeout for large organizations
    ...    pattern=^\d+$
    ...    default=900

    Set Suite Variable    ${ATLASSIAN_ORG_ID}    ${ATLASSIAN_ORG_ID}
    Set Suite Variable    ${ATLASSIAN_ORG_NAME}    ${ATLASSIAN_ORG_NAME}
    Set Suite Variable    ${ATLASSIAN_DIRECTORY_ID}    ${ATLASSIAN_DIRECTORY_ID}
    Set Suite Variable    ${INACTIVE_DAYS_THRESHOLD}    ${INACTIVE_DAYS_THRESHOLD}
    Set Suite Variable    ${PENDING_INVITE_DAYS_THRESHOLD}    ${PENDING_INVITE_DAYS_THRESHOLD}
    Set Suite Variable    ${MIN_OVERLAP_PRODUCTS}    ${MIN_OVERLAP_PRODUCTS}
    Set Suite Variable    ${PRODUCTS}    ${PRODUCTS}
    Set Suite Variable    ${RECLAMATION_MIN_SEATS}    ${RECLAMATION_MIN_SEATS}
    Set Suite Variable    ${TIMEOUT_SECONDS}    ${TIMEOUT_SECONDS}

    ${env}=    Create Dictionary
    ...    ATLASSIAN_ORG_ID=${ATLASSIAN_ORG_ID}
    ...    ATLASSIAN_ORG_NAME=${ATLASSIAN_ORG_NAME}
    ...    ATLASSIAN_DIRECTORY_ID=${ATLASSIAN_DIRECTORY_ID}
    ...    INACTIVE_DAYS_THRESHOLD=${INACTIVE_DAYS_THRESHOLD}
    ...    PENDING_INVITE_DAYS_THRESHOLD=${PENDING_INVITE_DAYS_THRESHOLD}
    ...    MIN_OVERLAP_PRODUCTS=${MIN_OVERLAP_PRODUCTS}
    ...    PRODUCTS=${PRODUCTS}
    ...    RECLAMATION_MIN_SEATS=${RECLAMATION_MIN_SEATS}
    ...    TIMEOUT_SECONDS=${TIMEOUT_SECONDS}
    Set Suite Variable    ${env}    ${env}
