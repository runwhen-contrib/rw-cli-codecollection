*** Settings ***
Documentation       Monitors AWS account cost trends and pushes a health metric. Returns 0 (unhealthy) if costs have increased beyond the configured threshold, 1 (healthy) otherwise.
Metadata            Author    stewartshea
Metadata            Display Name    AWS Account Cost Health
Metadata            Supports    AWS    Cost Management    Cost Reporting    Trend Analysis
Force Tags          AWS    Cost Management    Trend Analysis

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             Collections
Suite Setup         Suite Initialization


*** Tasks ***
Check Cost Trend for AWS Account `${AWS_ACCOUNT_NAME}` in Region `${AWS_REGION}`
    [Documentation]    Runs the AWS cost report and pushes a health metric based on cost trend analysis. Score is reduced only for severity 3 or below issues (significant cost increases).
    [Tags]    AWS    Cost Analysis    Cost Management    SLI    data:config
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=aws_cost_report.sh
    ...    env=${env}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false

    IF    ${process.returncode} != 0
        RW.Core.Push Metric    0    sub_name=cost_health
        RW.Core.Push Metric    0
        RETURN
    END

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat aws_cost_trend_issues.json 2>/dev/null || echo "[]"
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    ${actionable_issues}=    Evaluate    len([i for i in $issue_list if i.get("severity", 4) <= 3])
    IF    ${actionable_issues} > 0
        RW.Core.Push Metric    0    sub_name=cost_health
        RW.Core.Push Metric    0
    ELSE
        RW.Core.Push Metric    1    sub_name=cost_health
        RW.Core.Push Metric    1
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
    ...    description=AWS Region for Cost Explorer API calls
    ...    pattern=\w*
    ...    default=us-east-1
    ${AWS_ACCOUNT_NAME}=    RW.Core.Import User Variable    AWS_ACCOUNT_NAME
    ...    type=string
    ...    description=AWS account name or alias for display purposes
    ...    pattern=.*
    ...    default=""
    ${COST_ANALYSIS_LOOKBACK_DAYS}=    RW.Core.Import User Variable    COST_ANALYSIS_LOOKBACK_DAYS
    ...    type=string
    ...    description=Number of days to look back for cost analysis (default: 30)
    ...    pattern=\d+
    ...    default=30
    ${COST_INCREASE_THRESHOLD}=    RW.Core.Import User Variable    COST_INCREASE_THRESHOLD
    ...    type=string
    ...    description=Percentage threshold for cost increase alerts (default: 10 for 10% increase).
    ...    pattern=\d+
    ...    default=10
    ${TIMEOUT_SECONDS}=    RW.Core.Import User Variable    TIMEOUT_SECONDS
    ...    type=string
    ...    description=Timeout in seconds for tasks (default: 600 = 10 minutes).
    ...    pattern=\d+
    ...    default=600

    Set Suite Variable    ${AWS_REGION}    ${AWS_REGION}
    Set Suite Variable    ${AWS_ACCOUNT_NAME}    ${AWS_ACCOUNT_NAME}
    Set Suite Variable    ${COST_ANALYSIS_LOOKBACK_DAYS}    ${COST_ANALYSIS_LOOKBACK_DAYS}
    Set Suite Variable    ${COST_INCREASE_THRESHOLD}    ${COST_INCREASE_THRESHOLD}
    Set Suite Variable    ${TIMEOUT_SECONDS}    ${TIMEOUT_SECONDS}

    ${env}=    Create Dictionary
    ...    AWS_REGION=${AWS_REGION}
    ...    COST_ANALYSIS_LOOKBACK_DAYS=${COST_ANALYSIS_LOOKBACK_DAYS}
    ...    COST_INCREASE_THRESHOLD=${COST_INCREASE_THRESHOLD}
    Set Suite Variable    ${env}
