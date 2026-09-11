*** Settings ***
Documentation       Monitors GCP project-level service quotas across enabled services, flagging allocation quota usage vs limits, rate quota consumption and throttling events, quotas above a warning threshold, and quota rejection events in Cloud Logging.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Project Quota Health
Metadata            Supports    GCP,Project,Quota
Force Tags          GCP    Project    Quota    Health    Monitoring

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Check Allocation Quota Usage vs Limit for `${GCP_PROJECT_ID}`
    [Documentation]    Enumerates consumer allocation quota metrics for each enabled service via the Service Usage API and raises issues for allocation quotas at or near consumption of their configured limit.
    [Tags]    gcp    project    quota    allocation    data:config    access:read-only
    ${allocation_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_allocation_quotas.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=240
    ...    cmd_override=./check_allocation_quotas.sh
    ${allocation_issues}=    RW.CLI.Run Cli
    ...    cmd=cat allocation_quota_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${allocation_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for allocation quota analysis, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${allocation_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Allocation Quota Usage Analysis:\n${allocation_result.stdout}\n---\nFindings (JSON):\n${allocation_issues.stdout}

Check Rate Quota Consumption and Throttling Events for `${GCP_PROJECT_ID}`
    [Documentation]    Pulls Cloud Monitoring serviceruntime rate quota time-series over the lookback window, evaluates consumption against limits, and detects throttling events where requests were blocked by rate limits.
    [Tags]    gcp    project    quota    rate    data:metrics    access:read-only
    ${rate_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_rate_quotas.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=240
    ...    cmd_override=./check_rate_quotas.sh
    ${rate_issues}=    RW.CLI.Run Cli
    ...    cmd=cat rate_quota_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${rate_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for rate quota analysis, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${rate_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Rate Quota Consumption Analysis:\n${rate_result.stdout}\n---\nFindings (JSON):\n${rate_issues.stdout}

Identify Quotas Above `${QUOTA_WARNING_THRESHOLD}` for `${GCP_PROJECT_ID}`
    [Documentation]    Cross-references all discovered quota metrics (allocation and rate) against the configured warning threshold and raises an issue for every quota whose current usage equals or exceeds that threshold.
    [Tags]    gcp    project    quota    threshold    data:config    access:read-only
    ${threshold_result}=    RW.CLI.Run Bash File
    ...    bash_file=identify_quotas_above_threshold.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=240
    ...    cmd_override=./identify_quotas_above_threshold.sh
    ${threshold_issues}=    RW.CLI.Run Cli
    ...    cmd=cat quota_threshold_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${threshold_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for quota threshold analysis, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${threshold_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Quota Threshold Analysis:\n${threshold_result.stdout}\n---\nFindings (JSON):\n${threshold_issues.stdout}

Analyze Quota Rejection Events from Cloud Logging for `${GCP_PROJECT_ID}`
    [Documentation]    Queries Cloud Logging over the lookback window for quota rejection events (HTTP 429 RESOURCE_EXHAUSTED / quota exceeded) across services and raises issues when rejection volume exceeds the configured threshold.
    [Tags]    gcp    project    quota    logging    data:logs    access:read-only
    ${rejection_result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_quota_rejections.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=240
    ...    cmd_override=./analyze_quota_rejections.sh
    ${rejection_issues}=    RW.CLI.Run Cli
    ...    cmd=cat quota_rejection_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${rejection_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for quota rejection analysis, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${rejection_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Quota Rejection Analysis:\n${rejection_result.stdout}\n---\nFindings (JSON):\n${rejection_issues.stdout}


*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account JSON key used to authenticate with GCP APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID"}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=GCP Project ID whose quotas are monitored.
    ...    pattern=\w*
    ...    example=my-gcp-project
    ${QUOTA_WARNING_THRESHOLD}=    RW.Core.Import User Variable    QUOTA_WARNING_THRESHOLD
    ...    type=string
    ...    description=Usage percentage of a quota limit that triggers an issue (0-100).
    ...    pattern=^\d+(\.\d+)?$
    ...    default=80
    ${LOOKBACK_MINUTES}=    RW.Core.Import User Variable    LOOKBACK_MINUTES
    ...    type=string
    ...    description=Lookback window (minutes) for rate quota metrics and Cloud Logging rejection events.
    ...    pattern=^\d+$
    ...    default=1440
    ${SERVICES}=    RW.Core.Import User Variable    SERVICES
    ...    type=string
    ...    description=Comma-separated service names to limit quota checks to; 'All' checks every enabled service.
    ...    pattern=\w*
    ...    default=All
    ${REJECTION_THRESHOLD}=    RW.Core.Import User Variable    REJECTION_THRESHOLD
    ...    type=string
    ...    description=Minimum number of quota rejection events in the lookback window that triggers an issue.
    ...    pattern=^\d+$
    ...    default=1
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${QUOTA_WARNING_THRESHOLD}    ${QUOTA_WARNING_THRESHOLD}
    Set Suite Variable    ${LOOKBACK_MINUTES}    ${LOOKBACK_MINUTES}
    Set Suite Variable    ${SERVICES}    ${SERVICES}
    Set Suite Variable    ${REJECTION_THRESHOLD}    ${REJECTION_THRESHOLD}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_BILLING_QUOTA_PROJECT":"${GCP_PROJECT_ID}","CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","QUOTA_WARNING_THRESHOLD":"${QUOTA_WARNING_THRESHOLD}","LOOKBACK_MINUTES":"${LOOKBACK_MINUTES}","SERVICES":"${SERVICES}","REJECTION_THRESHOLD":"${REJECTION_THRESHOLD}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
