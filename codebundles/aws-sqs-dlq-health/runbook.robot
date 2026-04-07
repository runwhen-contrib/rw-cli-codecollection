*** Settings ***
Documentation       Monitors Amazon SQS dead-letter queues, raises issues when messages accumulate, samples DLQ messages for diagnostics, and correlates Lambda consumer CloudWatch logs for failures.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    AWS SQS Dead Letter Queue Health and Log Correlation
Metadata            Supports    AWS    SQS    DLQ    CloudWatch    Lambda
Force Tags          AWS    SQS    DLQ    CloudWatch    Lambda

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check Dead Letter Queue Depth and Redrive Configuration for Scope `${AWS_ACCOUNT_NAME}` Region `${AWS_REGION}`
    [Documentation]    Lists source queues, resolves RedrivePolicy to DLQs (deduped by DLQ ARN), compares ApproximateNumberOfMessages to DEAD_LETTER_MESSAGE_THRESHOLD, and emits structured issues when depth is exceeded.
    [Tags]    AWS    SQS    DLQ    Redrive    Metrics    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sqs_dlq_depth_and_redrive.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./sqs_dlq_depth_and_redrive.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat dlq_depth_issues.json 2>/dev/null || echo []
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
            ...    expected=DLQ approximate message count should stay at or below DEAD_LETTER_MESSAGE_THRESHOLD when the consumer is healthy
            ...    actual=DLQ depth or configuration issue detected for the scoped queues
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Sample Recent Dead Letter Messages for Diagnostics in Scope `${AWS_ACCOUNT_NAME}` Region `${AWS_REGION}`
    [Documentation]    Receives a bounded sample of DLQ messages with a short visibility timeout, returns visibility to zero, and records message attributes and body snippets for failure analysis.
    [Tags]    AWS    SQS    DLQ    Messages    Diagnostics    access:read-only    data:logs-bulk

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sqs_dlq_sample_messages.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./sqs_dlq_sample_messages.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat dlq_sample_issues.json 2>/dev/null || echo []
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for DLQ sample task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=DLQ messages should be rare when processing succeeds; samples should only appear during active incidents
            ...    actual=Sampled DLQ payloads and attributes are available for triage
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Correlate DLQ to Lambda Consumer CloudWatch Logs for Scope `${AWS_ACCOUNT_NAME}` Region `${AWS_REGION}`
    [Documentation]    For Lambda event source mappings on source queues, searches CloudWatch Logs in the lookback window for ERROR, task timeouts, and related failures. Degrades gracefully when the consumer is not Lambda.
    [Tags]    AWS    SQS    DLQ    Lambda    CloudWatch    Logs    access:read-only    data:logs-regexp

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sqs_dlq_lambda_consumer_logs.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./sqs_dlq_lambda_consumer_logs.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat dlq_lambda_logs_issues.json 2>/dev/null || echo []
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for Lambda logs task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Lambda consumers should process without repeated errors during the lookback window when the queue is healthy
            ...    actual=Lambda log correlation found errors or a non-Lambda consumer was detected while DLQ had messages
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Collect Source Queue CloudWatch Metrics for Context in Scope `${AWS_ACCOUNT_NAME}` Region `${AWS_REGION}`
    [Documentation]    Pulls AWS/SQS CloudWatch metrics for source queues to distinguish backlog growth from poison-message patterns and raises informational issues when oldest-message age is elevated.
    [Tags]    AWS    SQS    CloudWatch    Metrics    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sqs_source_queue_metrics.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./sqs_source_queue_metrics.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat sqs_source_metrics_issues.json 2>/dev/null || echo []
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for source metrics task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Source queue ApproximateAgeOfOldestMessage should remain low when consumers keep up with traffic
            ...    actual=Elevated oldest-message age or related backlog signal detected in CloudWatch metrics
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
    ...    description=AWS credentials from the workspace (from aws-auth block; e.g. aws:access_key@cli, aws:irsa@cli).
    ...    pattern=\w*

    ${AWS_REGION}=    RW.Core.Import User Variable    AWS_REGION
    ...    type=string
    ...    description=AWS region containing the queues
    ...    pattern=\w*
    ${AWS_ACCOUNT_NAME}=    RW.Core.Import User Variable    AWS_ACCOUNT_NAME
    ...    type=string
    ...    description=Account display name for reports
    ...    pattern=.*
    ...    default=Unknown
    ${SQS_QUEUE_URL}=    RW.Core.Import User Variable    SQS_QUEUE_URL
    ...    type=string
    ...    description=Optional single source queue URL (used with discovery qualifiers)
    ...    pattern=.*
    ...    default=
    ${SQS_QUEUE_URLS}=    RW.Core.Import User Variable    SQS_QUEUE_URLS
    ...    type=string
    ...    description=Comma-separated source queue URLs; empty uses discovery with optional prefix
    ...    pattern=.*
    ...    default=
    ${SQS_QUEUE_NAME_PREFIX}=    RW.Core.Import User Variable    SQS_QUEUE_NAME_PREFIX
    ...    type=string
    ...    description=Optional prefix filter for aws sqs list-queues discovery
    ...    pattern=.*
    ...    default=
    ${DEAD_LETTER_MESSAGE_THRESHOLD}=    RW.Core.Import User Variable    DEAD_LETTER_MESSAGE_THRESHOLD
    ...    type=string
    ...    description=Open an issue when DLQ approximate message count exceeds this integer
    ...    pattern=\d+
    ...    default=0
    ${CLOUDWATCH_LOG_LOOKBACK_MINUTES}=    RW.Core.Import User Variable    CLOUDWATCH_LOG_LOOKBACK_MINUTES
    ...    type=string
    ...    description=Lookback window for Lambda log search and metric alignment
    ...    pattern=\d+
    ...    default=30
    ${MAX_DLQ_MESSAGES_TO_SAMPLE}=    RW.Core.Import User Variable    MAX_DLQ_MESSAGES_TO_SAMPLE
    ...    type=string
    ...    description=Maximum DLQ messages to receive per run for diagnostics
    ...    pattern=\d+
    ...    default=5

    Set Suite Variable    ${AWS_REGION}    ${AWS_REGION}
    Set Suite Variable    ${AWS_ACCOUNT_NAME}    ${AWS_ACCOUNT_NAME}
    Set Suite Variable    ${SQS_QUEUE_URL}    ${SQS_QUEUE_URL}
    Set Suite Variable    ${SQS_QUEUE_URLS}    ${SQS_QUEUE_URLS}
    Set Suite Variable    ${SQS_QUEUE_NAME_PREFIX}    ${SQS_QUEUE_NAME_PREFIX}
    Set Suite Variable    ${DEAD_LETTER_MESSAGE_THRESHOLD}    ${DEAD_LETTER_MESSAGE_THRESHOLD}
    Set Suite Variable    ${CLOUDWATCH_LOG_LOOKBACK_MINUTES}    ${CLOUDWATCH_LOG_LOOKBACK_MINUTES}
    Set Suite Variable    ${MAX_DLQ_MESSAGES_TO_SAMPLE}    ${MAX_DLQ_MESSAGES_TO_SAMPLE}
    Set Suite Variable    ${aws_credentials}    ${aws_credentials}

    ${env}=    Create Dictionary
    ...    AWS_REGION=${AWS_REGION}
    ...    AWS_ACCOUNT_NAME=${AWS_ACCOUNT_NAME}
    ...    SQS_QUEUE_URL=${SQS_QUEUE_URL}
    ...    SQS_QUEUE_URLS=${SQS_QUEUE_URLS}
    ...    SQS_QUEUE_NAME_PREFIX=${SQS_QUEUE_NAME_PREFIX}
    ...    DEAD_LETTER_MESSAGE_THRESHOLD=${DEAD_LETTER_MESSAGE_THRESHOLD}
    ...    CLOUDWATCH_LOG_LOOKBACK_MINUTES=${CLOUDWATCH_LOG_LOOKBACK_MINUTES}
    ...    MAX_DLQ_MESSAGES_TO_SAMPLE=${MAX_DLQ_MESSAGES_TO_SAMPLE}
    Set Suite Variable    ${env}    ${env}
