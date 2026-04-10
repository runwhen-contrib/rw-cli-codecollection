*** Settings ***
Documentation       Measures SQS DLQ health as a 0–1 score: 1 when redrive/DLQ analysis reports no issues, otherwise 0.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    AWS SQS DLQ Health SLI
Metadata            Supports    AWS    SQS    DLQ    CloudWatch

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             String

Suite Setup         Suite Initialization


*** Tasks ***
Score DLQ Clearance for SQS Queues in `${AWS_REGION}`
    [Documentation]    Runs the redrive/DLQ depth check and maps an empty issue list to score 1, else 0.
    [Tags]    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sqs-redrive-and-dlq-depth.sh
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=AWS_REGION=${AWS_REGION} ./sqs-redrive-and-dlq-depth.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat redrive_dlq_issues.json
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        ${n}=    Get Length    ${issue_list}
        ${health_score}=    Evaluate    1 if ${n} == 0 else 0
    EXCEPT
        Log    SLI could not parse issue JSON; scoring 0.    WARN
        ${health_score}=    Set Variable    0
    END

    RW.Core.Add to Report    SQS DLQ health score: ${health_score}
    RW.Core.Push Metric    ${health_score}    sub_name=dlq_issue_count_clear
    RW.Core.Push Metric    ${health_score}


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
    ...    description=Comma-separated primary SQS queue URLs.
    ...    pattern=.*
    ...    default=
    ${RESOURCES}=    RW.Core.Import User Variable    RESOURCES
    ...    type=string
    ...    description=Queue name substring filter or All for discovery-driven runs.
    ...    pattern=.*
    ...    default=All
    ${DLQ_DEPTH_THRESHOLD}=    RW.Core.Import User Variable    DLQ_DEPTH_THRESHOLD
    ...    type=string
    ...    description=DLQ visible message count threshold for scoring context.
    ...    pattern=^[0-9]+$
    ...    default=0
    ${aws_credentials}=    RW.Core.Import Secret    aws_credentials
    ...    type=string
    ...    description=AWS credentials from the workspace aws-auth block.
    ...    pattern=\w*

    Set Suite Variable    ${AWS_REGION}    ${AWS_REGION}
    Set Suite Variable    ${AWS_ACCOUNT_NAME}    ${AWS_ACCOUNT_NAME}
    Set Suite Variable    ${SQS_QUEUE_URLS}    ${SQS_QUEUE_URLS}
    Set Suite Variable    ${RESOURCES}    ${RESOURCES}
    Set Suite Variable    ${DLQ_DEPTH_THRESHOLD}    ${DLQ_DEPTH_THRESHOLD}
    Set Suite Variable    ${aws_credentials}    ${aws_credentials}

    ${env}=    Create Dictionary
    ...    AWS_REGION=${AWS_REGION}
    ...    AWS_ACCOUNT_NAME=${AWS_ACCOUNT_NAME}
    ...    SQS_QUEUE_URLS=${SQS_QUEUE_URLS}
    ...    RESOURCES=${RESOURCES}
    ...    DLQ_DEPTH_THRESHOLD=${DLQ_DEPTH_THRESHOLD}
    Set Suite Variable    ${env}    ${env}
