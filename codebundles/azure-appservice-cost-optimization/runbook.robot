*** Settings ***
Documentation       Azure App Service Cost Optimization: Analyzes App Service Plans to identify empty plans, underutilized resources, and rightsizing opportunities with cost savings estimates. Supports three optimization strategies (aggressive/balanced/conservative) and provides comprehensive options tables with risk assessments.
Metadata            Author    stewartshea
Metadata            Display Name    Azure App Service Cost Optimization
Metadata            Supports    Azure    Cost Optimization    App Service Plans    Function Apps    Web Apps    Rightsizing
Force Tags          Azure    Cost Optimization    App Service Plans    Function Apps

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             Collections
Suite Setup         Suite Initialization


*** Tasks ***
Analyze App Service Plan Cost Optimization for Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Analyzes App Service Plans across subscriptions to identify empty plans, underutilized resources, and rightsizing opportunities with cost savings estimates. Supports three optimization strategies (aggressive/balanced/conservative) and provides comprehensive options tables with risk assessments for each plan.
    [Tags]    Azure    Cost Optimization    App Service Plans    Function Apps    Web Apps    Rightsizing    access:read-only
    ${cost_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=azure_appservice_cost_optimization.sh
    ...    env=${env}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${cost_analysis.stdout}

    # Generate summary statistics
    ${summary_cmd}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "azure_appservice_cost_optimization_issues.json" ]; then echo "Cost Health Analysis Summary:"; echo "============================"; jq -r 'group_by(.severity) | map({severity: .[0].severity, count: length}) | sort_by(.severity) | .[] | "Severity \\(.severity): \\(.count) issue(s)"' azure_appservice_cost_optimization_issues.json; echo ""; echo "Top Cost Savings Opportunities:"; jq -r 'sort_by(.severity) | limit(5; .[]) | "- \\(.title)"' azure_appservice_cost_optimization_issues.json; else echo "No cost analysis data available"; fi
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false
    
    RW.Core.Add Pre To Report    ${summary_cmd.stdout}
    
    # Extract potential savings totals if available
    ${savings_summary}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "azure_appservice_cost_optimization_report.txt" ]; then echo ""; echo "Detailed Analysis Report:"; echo "========================"; tail -20 azure_appservice_cost_optimization_report.txt; else echo "No detailed report available"; fi
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false
    
    RW.Core.Add Pre To Report    ${savings_summary.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat azure_appservice_cost_optimization_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0 
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=App Service Plans should be right-sized and actively used to minimize costs
            ...    actual=Cost optimization opportunities identified with potential savings from empty plans, underutilized resources, or rightsizing opportunities
            ...    title=${issue["title"]}
            ...    reproduce_hint=${cost_analysis.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_step"]}
        END
    ELSE
        RW.Core.Add Pre To Report    ✅ No significant cost optimization opportunities found. All App Service Plans appear to be efficiently utilized.
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
    ...    description=Comma-separated list of Azure subscription IDs to analyze for App Service optimization.
    ...    pattern=[\w,-]*
    ...    default=""
    ${AZURE_RESOURCE_GROUPS}=    RW.Core.Import User Variable    AZURE_RESOURCE_GROUPS
    ...    type=string
    ...    description=Comma-separated list of resource groups to analyze (leave empty to analyze all resource groups in the subscription)
    ...    pattern=[\w,-]*
    ...    default=""
    ${AZURE_SUBSCRIPTION_NAME}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_NAME
    ...    type=string
    ...    description=Azure subscription name for reporting purposes
    ...    pattern=.*
    ...    default=""
    ${LOW_COST_THRESHOLD}=    RW.Core.Import User Variable    LOW_COST_THRESHOLD
    ...    type=string
    ...    description=Monthly savings threshold for LOW classification (default: 500)
    ...    pattern=\d+
    ...    default=500
    ${MEDIUM_COST_THRESHOLD}=    RW.Core.Import User Variable    MEDIUM_COST_THRESHOLD
    ...    type=string
    ...    description=Monthly savings threshold for MEDIUM classification (default: 2000)
    ...    pattern=\d+
    ...    default=2000
    ${HIGH_COST_THRESHOLD}=    RW.Core.Import User Variable    HIGH_COST_THRESHOLD
    ...    type=string
    ...    description=Monthly savings threshold for HIGH classification (default: 10000)
    ...    pattern=\d+
    ...    default=10000
    ${OPTIMIZATION_STRATEGY}=    RW.Core.Import User Variable    OPTIMIZATION_STRATEGY
    ...    type=string
    ...    description=Optimization strategy: 'aggressive' (max savings, 85-90% target CPU, dev/test), 'balanced' (default, 75-80% target CPU, standard prod), or 'conservative' (safest, 60-70% target CPU, critical prod)
    ...    pattern=(aggressive|balanced|conservative)
    ...    default=balanced
    ${TIMEOUT_SECONDS}=    RW.Core.Import User Variable    TIMEOUT_SECONDS
    ...    type=string
    ...    description=Timeout in seconds for tasks (default: 1500 = 25 minutes).
    ...    pattern=\d+
    ...    default=1500
    
    Set Suite Variable    ${AZURE_SUBSCRIPTION_IDS}    ${AZURE_SUBSCRIPTION_IDS}
    Set Suite Variable    ${AZURE_RESOURCE_GROUPS}    ${AZURE_RESOURCE_GROUPS}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_NAME}    ${AZURE_SUBSCRIPTION_NAME}
    Set Suite Variable    ${LOW_COST_THRESHOLD}    ${LOW_COST_THRESHOLD}
    Set Suite Variable    ${MEDIUM_COST_THRESHOLD}    ${MEDIUM_COST_THRESHOLD}
    Set Suite Variable    ${HIGH_COST_THRESHOLD}    ${HIGH_COST_THRESHOLD}
    Set Suite Variable    ${OPTIMIZATION_STRATEGY}    ${OPTIMIZATION_STRATEGY}
    Set Suite Variable    ${TIMEOUT_SECONDS}    ${TIMEOUT_SECONDS}
    
    ${env}=    Create Dictionary
    ...    AZURE_SUBSCRIPTION_IDS=${AZURE_SUBSCRIPTION_IDS}
    ...    AZURE_RESOURCE_GROUPS=${AZURE_RESOURCE_GROUPS}
    ...    LOW_COST_THRESHOLD=${LOW_COST_THRESHOLD}
    ...    MEDIUM_COST_THRESHOLD=${MEDIUM_COST_THRESHOLD}
    ...    HIGH_COST_THRESHOLD=${HIGH_COST_THRESHOLD}
    ...    OPTIMIZATION_STRATEGY=${OPTIMIZATION_STRATEGY}
    Set Suite Variable    ${env}
