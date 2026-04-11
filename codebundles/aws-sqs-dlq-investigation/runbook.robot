*** Settings ***
Documentation       Investigates Amazon SQS dead-letter queues by correlating queue configuration, DLQ backlog, sampled messages, Lambda consumers, and CloudWatch logs and metrics.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    AWS SQS Dead Letter Queue Investigation
Metadata            Supports    AWS    SQS    Lambda    CloudWatch

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization

Force Tags          AWS    SQS    DLQ    Lambda    CloudWatch


*** Tasks ***
Check SQS Redrive Policy and DLQ Depth for Queues in `${AWS_REGION}` `${AWS_ACCOUNT_NAME}`
    [Documentation]    Reads RedrivePolicy and DLQ attributes, flags backlog versus DLQ_DEPTH_THRESHOLD and stale message age.
    [Tags]    AWS    SQS    DLQ    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sqs-redrive-and-dlq-depth.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=AWS_REGION=${AWS_REGION} ./sqs-redrive-and-dlq-depth.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat redrive_dlq_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for redrive/DLQ task.    WARN
        ${issue_list}=    Create List
    END
    ${n}=    Get Length    ${issue_list}
    IF    ${n} > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=DLQ depth within threshold and healthy redrive configuration for the primary queue
            ...    actual=Issue detected during redrive policy or DLQ depth analysis
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Peek Sample Messages on Dead Letter Queues in `${AWS_REGION}`
    [Documentation]    Non-destructively receives a limited batch from each DLQ with a short visibility timeout for operator review.
    [Tags]    AWS    SQS    DLQ    access:read-only    data:logs-bulk

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sqs-peek-dlq-messages.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=AWS_REGION=${AWS_REGION} ./sqs-peek-dlq-messages.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat peek_dlq_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for peek DLQ task.    WARN
        ${issue_list}=    Create List
    END
    ${n}=    Get Length    ${issue_list}
    IF    ${n} > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=No unexpected DLQ sample issues for review (empty DLQ or successful peek)
            ...    actual=Peek or context issue reported
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Discover Lambda Consumers for SQS Queues in `${AWS_REGION}`
    [Documentation]    Lists Lambda event source mappings for each primary queue ARN to support log correlation.
    [Tags]    AWS    Lambda    SQS    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sqs-discover-lambda-consumers.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=AWS_REGION=${AWS_REGION} ./sqs-discover-lambda-consumers.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat discover_lambda_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for Lambda discovery task.    WARN
        ${issue_list}=    Create List
    END
    ${n}=    Get Length    ${issue_list}
    IF    ${n} > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Lambda event source mappings exist for SQS-driven processing when Lambda is the consumer
            ...    actual=No Lambda mappings found or context missing
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Fetch Recent Lambda Processor Errors from CloudWatch Logs in `${AWS_REGION}`
    [Documentation]    Searches Lambda (and optional extra) log groups for errors within the lookback window.
    [Tags]    AWS    CloudWatch    Logs    Lambda    access:read-only    data:logs-regexp

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sqs-fetch-lambda-error-logs.sh
    ...    env=${env}
    ...    timeout_seconds=240
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=AWS_REGION=${AWS_REGION} ./sqs-fetch-lambda-error-logs.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat fetch_lambda_logs_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for Lambda log fetch task.    WARN
        ${issue_list}=    Create List
    END
    ${n}=    Get Length    ${issue_list}
    IF    ${n} > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=No ERROR or timeout patterns in processor logs during the lookback window
            ...    actual=Matching log events found or log scan could not run
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Summarize CloudWatch Metrics for SQS Queues and DLQs in `${AWS_REGION}`
    [Documentation]    Optional traffic and backlog snapshot via CloudWatch metrics for the primary queue and DLQ.
    [Tags]    AWS    SQS    CloudWatch    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sqs-cloudwatch-queue-metrics.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=AWS_REGION=${AWS_REGION} ./sqs-cloudwatch-queue-metrics.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat cloudwatch_queue_metrics_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for CloudWatch metrics task.    WARN
        ${issue_list}=    Create List
    END
    ${n}=    Get Length    ${issue_list}
    IF    ${n} > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=No additional metric anomalies reported by this snapshot task
            ...    actual=Metric-related issue entry present
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END


*** Keywords ***
Suite Initialization
    ${AWS_REGION}=    RW.Core.Import User Variable    AWS_REGION
    ...    type=string
    ...    description=AWS region containing the queues.
    ...    pattern=\w*
    ${AWS_ACCOUNT_NAME}=    RW.Core.Import User Variable    AWS_ACCOUNT_NAME
    ...    type=string
    ...    description=Human-readable account alias for titles and reports.
    ...    pattern=.*
    ...    default=
    ${SQS_QUEUE_URLS}=    RW.Core.Import User Variable    SQS_QUEUE_URLS
    ...    type=string
    ...    description=Comma-separated primary SQS queue URLs (optional if listing by RESOURCES).
    ...    pattern=.*
    ...    default=
    ${RESOURCES}=    RW.Core.Import User Variable    RESOURCES
    ...    type=string
    ...    description=Queue name substring filter or All for discovery-driven runs.
    ...    pattern=.*
    ...    default=All
    ${DLQ_DEPTH_THRESHOLD}=    RW.Core.Import User Variable    DLQ_DEPTH_THRESHOLD
    ...    type=string
    ...    description=Flag DLQ when ApproximateNumberOfMessagesVisible exceeds this value (0 means any message is an issue).
    ...    pattern=^[0-9]+$
    ...    default=0
    ${CLOUDWATCH_LOG_LOOKBACK_MINUTES}=    RW.Core.Import User Variable    CLOUDWATCH_LOG_LOOKBACK_MINUTES
    ...    type=string
    ...    description=How far back to search processor logs for errors.
    ...    pattern=^[0-9]+$
    ...    default=60
    ${EXTRA_LOG_GROUP_NAMES}=    RW.Core.Import User Variable    EXTRA_LOG_GROUP_NAMES
    ...    type=string
    ...    description=Optional extra CloudWatch log groups for non-Lambda processors.
    ...    pattern=.*
    ...    default=
    ${MAX_DLQ_SAMPLE_MESSAGES}=    RW.Core.Import User Variable    MAX_DLQ_SAMPLE_MESSAGES
    ...    type=string
    ...    description=Maximum DLQ messages to sample per queue in one run.
    ...    pattern=^[0-9]+$
    ...    default=5
    ${aws_credentials}=    RW.Core.Import Secret    aws_credentials
    ...    type=string
    ...    description=AWS credentials from the workspace aws-auth block.
    ...    pattern=\w*

    Set Suite Variable    ${AWS_REGION}    ${AWS_REGION}
    Set Suite Variable    ${AWS_ACCOUNT_NAME}    ${AWS_ACCOUNT_NAME}
    Set Suite Variable    ${SQS_QUEUE_URLS}    ${SQS_QUEUE_URLS}
    Set Suite Variable    ${RESOURCES}    ${RESOURCES}
    Set Suite Variable    ${DLQ_DEPTH_THRESHOLD}    ${DLQ_DEPTH_THRESHOLD}
    Set Suite Variable    ${CLOUDWATCH_LOG_LOOKBACK_MINUTES}    ${CLOUDWATCH_LOG_LOOKBACK_MINUTES}
    Set Suite Variable    ${EXTRA_LOG_GROUP_NAMES}    ${EXTRA_LOG_GROUP_NAMES}
    Set Suite Variable    ${MAX_DLQ_SAMPLE_MESSAGES}    ${MAX_DLQ_SAMPLE_MESSAGES}
    Set Suite Variable    ${aws_credentials}    ${aws_credentials}

    ${env}=    Create Dictionary
    ...    AWS_REGION=${AWS_REGION}
    ...    AWS_ACCOUNT_NAME=${AWS_ACCOUNT_NAME}
    ...    SQS_QUEUE_URLS=${SQS_QUEUE_URLS}
    ...    RESOURCES=${RESOURCES}
    ...    DLQ_DEPTH_THRESHOLD=${DLQ_DEPTH_THRESHOLD}
    ...    CLOUDWATCH_LOG_LOOKBACK_MINUTES=${CLOUDWATCH_LOG_LOOKBACK_MINUTES}
    ...    EXTRA_LOG_GROUP_NAMES=${EXTRA_LOG_GROUP_NAMES}
    ...    MAX_DLQ_SAMPLE_MESSAGES=${MAX_DLQ_SAMPLE_MESSAGES}
    Set Suite Variable    ${env}    ${env}
