*** Settings ***
Documentation       AWS Account Cost Report: Generates historical cost breakdown reports by service using the AWS Cost Explorer API. Includes period-over-period comparison, raises an issue if cost increase exceeds configured threshold, and provides Reserved Instance and Savings Plans purchase recommendations.
Metadata            Author    stewartshea
Metadata            Display Name    AWS Account Cost Report
Metadata            Supports    AWS    Cost Management    Cost Reporting    Trend Analysis    Reserved Instances    Savings Plans
Force Tags          AWS    Cost Management    Cost Reporting    Trend Analysis

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             Collections
Suite Setup         Suite Initialization


*** Tasks ***
Generate AWS Cost Report By Service for Account `${AWS_ACCOUNT_NAME}`
    [Documentation]    Generates a detailed cost breakdown report for the configured lookback period showing actual spending by AWS service. Includes period-over-period comparison and raises an issue if cost increase exceeds configured threshold.
    [Tags]    AWS    Cost Analysis    Cost Management    Reporting    Trend Analysis    access:read-only    data:config
    ${cost_report}=    RW.CLI.Run Bash File
    ...    bash_file=aws_cost_report.sh
    ...    env=${env}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true

    IF    ${cost_report.returncode} == -1
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=AWS cost report should complete within timeout for account `${AWS_ACCOUNT_NAME}`
        ...    actual=AWS cost report timed out for account `${AWS_ACCOUNT_NAME}`
        ...    title=AWS Cost Report Timeout for Account `${AWS_ACCOUNT_NAME}`
        ...    reproduce_hint=${cost_report.cmd}
        ...    details=Command timed out. This may indicate authentication issues, network problems, or Cost Explorer API delays.
        ...    next_steps=Check AWS credentials with 'aws sts get-caller-identity'\nVerify Cost Explorer is enabled in the billing console\nCheck that the IAM role has ce:GetCostAndUsage permission
        RETURN
    END

    ${auth_failed}=    Run Keyword And Return Status    Should Contain    ${cost_report.stdout}    AWS credentials not configured
    IF    ${auth_failed}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=AWS authentication should succeed for cost analysis on account `${AWS_ACCOUNT_NAME}`
        ...    actual=AWS authentication failed for account `${AWS_ACCOUNT_NAME}`
        ...    title=AWS Authentication Failed for Cost Report on Account `${AWS_ACCOUNT_NAME}`
        ...    reproduce_hint=${cost_report.cmd}
        ...    details=${cost_report.stdout}
        ...    next_steps=Verify AWS credentials are configured via the platform aws-auth block\nCheck that the aws_credentials secret is properly bound in the workspace\nTest authentication: aws sts get-caller-identity
        RETURN
    END

    RW.Core.Add Pre To Report    ${cost_report.stdout}
    RW.Core.Add Pre To Report    ${cost_report.stderr}

    ${trend_issues}=    RW.CLI.Run Cli
    ...    cmd=cat aws_cost_trend_issues.json 2>/dev/null || echo "[]"
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ${trend_issue_list}=    Evaluate    json.loads(r'''${trend_issues.stdout}''')    json
    IF    len(@{trend_issue_list}) > 0
        FOR    ${issue}    IN    @{trend_issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=AWS costs should remain stable or decrease over time through optimization efforts
            ...    actual=Significant cost increase detected that exceeds the configured alert threshold
            ...    title=${issue["title"]}
            ...    reproduce_hint=${cost_report.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_step"]}
        END
    END


Analyze AWS Reserved Instance and Savings Plans Recommendations for Account `${AWS_ACCOUNT_NAME}`
    [Documentation]    Queries AWS Cost Explorer for Reserved Instance and Savings Plans purchase recommendations. Calculates potential savings from commitments for EC2, RDS, ElastiCache, and Compute Savings Plans.
    [Tags]    AWS    Cost Analysis    Reserved Instances    Savings Plans    access:read-only    data:config
    ${ri_report}=    RW.CLI.Run Bash File
    ...    bash_file=aws_ri_recommendations.sh
    ...    env=${env}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true

    IF    ${ri_report.returncode} == -1
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=RI/Savings Plans analysis should complete within timeout for account `${AWS_ACCOUNT_NAME}`
        ...    actual=RI/Savings Plans analysis timed out for account `${AWS_ACCOUNT_NAME}`
        ...    title=RI/Savings Plans Analysis Timeout for Account `${AWS_ACCOUNT_NAME}`
        ...    reproduce_hint=${ri_report.cmd}
        ...    details=Command timed out. This may indicate authentication issues or API throttling.
        ...    next_steps=Check AWS credentials\nVerify IAM permissions include ce:GetReservationPurchaseRecommendation and ce:GetSavingsPlansPurchaseRecommendation
        RETURN
    END

    ${auth_failed}=    Run Keyword And Return Status    Should Contain    ${ri_report.stdout}    AWS credentials not configured
    IF    ${auth_failed}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=AWS authentication should succeed for RI analysis on account `${AWS_ACCOUNT_NAME}`
        ...    actual=AWS authentication failed for account `${AWS_ACCOUNT_NAME}`
        ...    title=AWS Authentication Failed for RI Analysis on Account `${AWS_ACCOUNT_NAME}`
        ...    reproduce_hint=${ri_report.cmd}
        ...    details=${ri_report.stdout}
        ...    next_steps=Verify AWS credentials are configured via the platform aws-auth block\nCheck that the aws_credentials secret is properly bound in the workspace
        RETURN
    END

    RW.Core.Add Pre To Report    ${ri_report.stdout}

    ${ri_issues}=    RW.CLI.Run Cli
    ...    cmd=cat aws_ri_issues.json 2>/dev/null || echo "[]"
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ${ri_issue_list}=    Evaluate    json.loads(r'''${ri_issues.stdout}''')    json
    IF    len(@{ri_issue_list}) > 0
        FOR    ${issue}    IN    @{ri_issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=Reserved Instance and Savings Plans opportunities should be evaluated to reduce AWS spending
            ...    actual=AWS Cost Explorer has identified potential savings through commitments
            ...    title=${issue["title"]}
            ...    reproduce_hint=${ri_report.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_step"]}
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
    ...    description=Percentage threshold for cost increase alerts. An issue will be raised if period-over-period cost increase exceeds this value (e.g., 10 for 10% increase).
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
