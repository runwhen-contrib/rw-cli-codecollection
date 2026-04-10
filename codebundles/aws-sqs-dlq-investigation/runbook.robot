*** Settings ***
Documentation       Automates triage when Amazon SQS messages land in a dead-letter queue by inspecting queue configuration, DLQ depth and age, discovering Lambda event source mappings, and searching CloudWatch logs for consumer failures.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    AWS SQS Dead-Letter Queue Investigation
Metadata            Supports    AWS SQS DLQ Lambda CloudWatch Logs
Force Tags          AWS    SQS    DLQ    Lambda    CloudWatch    Investigation

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Inspect SQS Queue and DLQ Configuration for `${SQS_QUEUE_NAME}` in `${AWS_REGION}`
    [Documentation]    Reads the primary queue URL or name, attributes, and redrive policy to resolve the DLQ and surfaces missing or unreachable DLQ configuration.
    [Tags]    AWS    SQS    DLQ    Configuration    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=inspect_sqs_dlq_config.sh
    ...    env=${env}
    ...    secret__aws_credentials=${aws_credentials}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=AWS_REGION=${AWS_REGION} SQS_QUEUE_URL=${SQS_QUEUE_URL} SQS_QUEUE_NAME=${SQS_QUEUE_NAME} ./inspect_sqs_dlq_config.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat inspect_sqs_dlq_config_issues.json 2>/dev/null || echo []
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for inspect task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Primary queue should have a valid redrive policy and reachable DLQ when messages fail processing
            ...    actual=Configuration inspection found problems with the primary queue or DLQ setup
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Report DLQ Depth and Age Signals for `${SQS_QUEUE_NAME}` in `${AWS_REGION}`
    [Documentation]    Reports approximate DLQ message count and ApproximateAgeOfOldestMessage from CloudWatch and raises issues when depth exceeds the configured threshold.
    [Tags]    AWS    SQS    DLQ    Metrics    CloudWatch    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=report_dlq_depth_and_age.sh
    ...    env=${env}
    ...    secret__aws_credentials=${aws_credentials}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=AWS_REGION=${AWS_REGION} DLQ_DEPTH_THRESHOLD=${DLQ_DEPTH_THRESHOLD} ./report_dlq_depth_and_age.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat report_dlq_depth_issues.json 2>/dev/null || echo []
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for DLQ depth task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=DLQ depth should be at or below the configured threshold when the system is healthy
            ...    actual=DLQ backlog or age signals indicate dead-letter accumulation
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Discover Lambda Event Source Mappings for Queue `${SQS_QUEUE_NAME}` in `${AWS_REGION}`
    [Documentation]    Lists Lambda event source mappings that reference the primary queue ARN so downstream log groups can be targeted automatically.
    [Tags]    AWS    SQS    Lambda    EventSourceMapping    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=discover_lambda_esm_for_queue.sh
    ...    env=${env}
    ...    secret__aws_credentials=${aws_credentials}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=AWS_REGION=${AWS_REGION} ./discover_lambda_esm_for_queue.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat discover_lambda_esm_issues.json 2>/dev/null || echo []
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for discovery task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Lambda consumers should be discoverable via event source mappings when Lambda processes the queue
            ...    actual=Discovery found informational notes about Lambda mappings for this queue
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Query CloudWatch Logs for Processing Failures for `${SQS_QUEUE_NAME}` in `${AWS_REGION}`
    [Documentation]    Searches discovered Lambda log groups and optional extra groups for ERROR and exception patterns within the configured lookback window.
    [Tags]    AWS    CloudWatch    Logs    Lambda    access:read-only    data:logs-regexp

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=query_cw_logs_for_sqs_failures.sh
    ...    env=${env}
    ...    secret__aws_credentials=${aws_credentials}
    ...    timeout_seconds=${QUERY_TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=AWS_REGION=${AWS_REGION} LOG_LOOKBACK_MINUTES=${LOG_LOOKBACK_MINUTES} ./query_cw_logs_for_sqs_failures.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat query_cw_logs_issues.json 2>/dev/null || echo []
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for log query task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Consumer logs should be free of unhandled errors during steady operation
            ...    actual=Log search found error or failure patterns in the lookback window
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Summarize DLQ Triage Findings for `${SQS_QUEUE_NAME}` in `${AWS_REGION}`
    [Documentation]    Consolidates configuration, metrics, and log signals into a concise report and raises cross-cutting issues when DLQ backlog coexists with log evidence of failures.
    [Tags]    AWS    SQS    DLQ    Summary    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=summarize_sqs_dlq_findings.sh
    ...    env=${env}
    ...    secret__aws_credentials=${aws_credentials}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./summarize_sqs_dlq_findings.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat summarize_sqs_dlq_findings_issues.json 2>/dev/null || echo []
    ...    env=${env}
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
            ...    expected=DLQ triage should either show a clean bill of health or clear remediation paths without contradictory signals
            ...    actual=Summary detected DLQ backlog together with supporting log evidence of consumer failures
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END


*** Keywords ***
Suite Initialization
    ${aws_credentials}=    RW.Core.Import Secret
    ...    aws_credentials
    ...    type=string
    ...    description=AWS credentials from the workspace aws-auth block (read-only SQS, Lambda, Logs, CloudWatch).
    ...    pattern=\w*

    ${AWS_REGION}=    RW.Core.Import User Variable    AWS_REGION
    ...    type=string
    ...    description=AWS region containing the queues.
    ...    pattern=[a-z0-9-]+

    ${AWS_ACCOUNT_NAME}=    RW.Core.Import User Variable    AWS_ACCOUNT_NAME
    ...    type=string
    ...    description=Human-readable account alias or name for reports.
    ...    pattern=.*
    ...    default=Unknown

    ${SQS_QUEUE_URL}=    RW.Core.Import User Variable    SQS_QUEUE_URL
    ...    type=string
    ...    description=Full HTTPS URL of the primary queue when known.
    ...    pattern=.*
    ...    default=

    ${SQS_QUEUE_NAME}=    RW.Core.Import User Variable    SQS_QUEUE_NAME
    ...    type=string
    ...    description=Primary queue name when the URL is built from discovery or convention.
    ...    pattern=.*
    ...    default=

    ${CLOUDWATCH_LOG_GROUPS}=    RW.Core.Import User Variable    CLOUDWATCH_LOG_GROUPS
    ...    type=string
    ...    description=Comma-separated extra log group names to search (ECS, EC2, applications).
    ...    pattern=.*
    ...    default=

    ${LOG_LOOKBACK_MINUTES}=    RW.Core.Import User Variable    LOG_LOOKBACK_MINUTES
    ...    type=string
    ...    description=CloudWatch Logs lookback window in minutes.
    ...    pattern=^\d+$
    ...    default=120

    ${DLQ_DEPTH_THRESHOLD}=    RW.Core.Import User Variable    DLQ_DEPTH_THRESHOLD
    ...    type=string
    ...    description=Raise an issue when approximate DLQ messages exceed this count.
    ...    pattern=^\d+$
    ...    default=0

    ${TIMEOUT_SECONDS}=    RW.Core.Import User Variable    TIMEOUT_SECONDS
    ...    type=string
    ...    description=Timeout in seconds for bash tasks (except log query).
    ...    pattern=^\d+$
    ...    default=240

    ${QUERY_TIMEOUT_SECONDS}=    RW.Core.Import User Variable    QUERY_TIMEOUT_SECONDS
    ...    type=string
    ...    description=Timeout in seconds for CloudWatch log search.
    ...    pattern=^\d+$
    ...    default=300

    Set Suite Variable    ${aws_credentials}    ${aws_credentials}
    Set Suite Variable    ${AWS_REGION}    ${AWS_REGION}
    Set Suite Variable    ${AWS_ACCOUNT_NAME}    ${AWS_ACCOUNT_NAME}
    Set Suite Variable    ${SQS_QUEUE_URL}    ${SQS_QUEUE_URL}
    Set Suite Variable    ${SQS_QUEUE_NAME}    ${SQS_QUEUE_NAME}
    Set Suite Variable    ${CLOUDWATCH_LOG_GROUPS}    ${CLOUDWATCH_LOG_GROUPS}
    Set Suite Variable    ${LOG_LOOKBACK_MINUTES}    ${LOG_LOOKBACK_MINUTES}
    Set Suite Variable    ${DLQ_DEPTH_THRESHOLD}    ${DLQ_DEPTH_THRESHOLD}
    Set Suite Variable    ${TIMEOUT_SECONDS}    ${TIMEOUT_SECONDS}
    Set Suite Variable    ${QUERY_TIMEOUT_SECONDS}    ${QUERY_TIMEOUT_SECONDS}

    ${env}=    Create Dictionary
    ...    AWS_REGION=${AWS_REGION}
    ...    AWS_ACCOUNT_NAME=${AWS_ACCOUNT_NAME}
    ...    SQS_QUEUE_URL=${SQS_QUEUE_URL}
    ...    SQS_QUEUE_NAME=${SQS_QUEUE_NAME}
    ...    CLOUDWATCH_LOG_GROUPS=${CLOUDWATCH_LOG_GROUPS}
    ...    LOG_LOOKBACK_MINUTES=${LOG_LOOKBACK_MINUTES}
    ...    DLQ_DEPTH_THRESHOLD=${DLQ_DEPTH_THRESHOLD}
    Set Suite Variable    ${env}    ${env}
