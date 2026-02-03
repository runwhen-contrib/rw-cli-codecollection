*** Settings ***
Documentation       Azure Cost Report: Generates historical cost breakdown reports by service and resource group using the Cost Management API. Includes period-over-period comparison, raises an issue if cost increase exceeds configured threshold, and provides Reserved Instance purchase recommendations from Azure Advisor.
Metadata            Author    stewartshea
Metadata            Display Name    Azure Subscription Cost Report
Metadata            Supports    Azure    Cost Management    Cost Reporting    Trend Analysis    Reserved Instances
Force Tags          Azure    Cost Management    Cost Reporting    Trend Analysis    Reserved Instances

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             Collections
Suite Setup         Suite Initialization


*** Tasks ***
Generate Azure Cost Report By Service and Resource Group for Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Generates a detailed cost breakdown report for the last 30 days showing actual spending by resource group and Azure service using the Cost Management API. Includes period-over-period comparison and raises an issue if cost increase exceeds configured threshold.
    [Tags]    Azure    Cost Analysis    Cost Management    Reporting    Trend Analysis    access:read-only
    ${cost_report}=    RW.CLI.Run Bash File
    ...    bash_file=azure_cost_historical_report.sh
    ...    env=${env}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${cost_report.stdout}
    RW.Core.Add Pre To Report    ${cost_report.stderr}
    
    # Check for cost trend issues
    ${trend_issues}=    RW.CLI.Run Cli
    ...    cmd=cat azure_cost_trend_issues.json
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ${trend_issue_list}=    Evaluate    json.loads(r'''${trend_issues.stdout}''')    json
    IF    len(@{trend_issue_list}) > 0 
        FOR    ${issue}    IN    @{trend_issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=Azure costs should remain stable or decrease over time through optimization efforts
            ...    actual=Significant cost increase detected that exceeds the configured alert threshold
            ...    title=${issue["title"]}
            ...    reproduce_hint=${cost_report.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_step"]}
        END
    END


Analyze Azure Advisor Reserved Instance Recommendations for Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Queries Azure Advisor and the Reservations API to identify Reserved Instance purchase opportunities. Calculates potential savings from 1-year and 3-year commitments for VMs, App Service Plans, and other eligible resources.
    [Tags]    Azure    Cost Analysis    Reserved Instances    Advisor    Savings    access:read-only
    ${ri_report}=    RW.CLI.Run Bash File
    ...    bash_file=azure_advisor_reservation_recommendations.sh
    ...    env=${env}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${ri_report.stdout}
    
    # Check for RI recommendation issues
    ${ri_issues}=    RW.CLI.Run Cli
    ...    cmd=cat azure_advisor_ri_issues.json 2>/dev/null || echo "[]"
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ${ri_issue_list}=    Evaluate    json.loads(r'''${ri_issues.stdout}''')    json
    IF    len(@{ri_issue_list}) > 0 
        FOR    ${issue}    IN    @{ri_issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=Reserved Instance opportunities should be evaluated to reduce Azure spending
            ...    actual=Azure Advisor has identified potential savings through Reserved Instance purchases
            ...    title=${issue["title"]}
            ...    reproduce_hint=${ri_report.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_step"]}
        END
    END


*** Keywords ***
Suite Initialization
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET
    ...    pattern=\w*
    ${AZURE_SUBSCRIPTION_IDS}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_IDS
    ...    type=string
    ...    description=Comma-separated list of Azure subscription IDs to analyze for cost reporting (e.g., "sub1,sub2,sub3"). Leave empty to use current subscription.
    ...    pattern=[\w,-]*
    ...    default=""
    ${AZURE_SUBSCRIPTION_NAME}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_NAME
    ...    type=string
    ...    description=Azure subscription name for reporting purposes
    ...    pattern=.*
    ...    default=""
    ${COST_ANALYSIS_LOOKBACK_DAYS}=    RW.Core.Import User Variable    COST_ANALYSIS_LOOKBACK_DAYS
    ...    type=string
    ...    description=Number of days to look back for cost analysis (default: 30)
    ...    pattern=\d+
    ...    default=30
    ${COST_INCREASE_THRESHOLD}=    RW.Core.Import User Variable    COST_INCREASE_THRESHOLD
    ...    type=string
    ...    description=Percentage threshold for cost increase alerts. An issue will be raised if period-over-period cost increase exceeds this value (e.g., 10 for 10% increase, default: 10)
    ...    pattern=\d+
    ...    default=10
    ${TIMEOUT_SECONDS}=    RW.Core.Import User Variable    TIMEOUT_SECONDS
    ...    type=string
    ...    description=Timeout in seconds for tasks (default: 1500 = 25 minutes).
    ...    pattern=\d+
    ...    default=1500
    
    # Set suite variables
    Set Suite Variable    ${AZURE_SUBSCRIPTION_IDS}    ${AZURE_SUBSCRIPTION_IDS}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_NAME}    ${AZURE_SUBSCRIPTION_NAME}
    Set Suite Variable    ${COST_ANALYSIS_LOOKBACK_DAYS}    ${COST_ANALYSIS_LOOKBACK_DAYS}
    Set Suite Variable    ${COST_INCREASE_THRESHOLD}    ${COST_INCREASE_THRESHOLD}
    Set Suite Variable    ${TIMEOUT_SECONDS}    ${TIMEOUT_SECONDS}
    
    # Create environment variables for the bash script
    ${env}=    Create Dictionary
    ...    AZURE_SUBSCRIPTION_IDS=${AZURE_SUBSCRIPTION_IDS}
    ...    COST_ANALYSIS_LOOKBACK_DAYS=${COST_ANALYSIS_LOOKBACK_DAYS}
    ...    COST_INCREASE_THRESHOLD=${COST_INCREASE_THRESHOLD}
    Set Suite Variable    ${env}
