*** Settings ***
Documentation       Azure AKS Cost Optimization: Analyzes AKS cluster node pools to identify cost optimization opportunities by examining CPU/memory utilization and providing capacity-planned recommendations for reducing minimum node counts or changing VM types.
Metadata            Author    stewartshea
Metadata            Display Name    Azure AKS Cost Optimization
Metadata            Supports    Azure    Cost Optimization    AKS    Kubernetes    Node Pools    Autoscaling    Capacity Planning
Force Tags          Azure    Cost Optimization    AKS    Kubernetes    Node Pools

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             Collections
Suite Setup         Suite Initialization


*** Tasks ***
Analyze AKS Node Pool Resizing Opportunities Based on Utilization Metrics in Resource Group `${AZURE_RESOURCE_GROUPS}` for Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Analyzes AKS cluster node pools across specified subscriptions, examines both average and peak CPU/memory utilization over the past 30 days, and provides capacity-planned recommendations for reducing minimum node counts or changing VM types to optimize costs. Uses a two-tier approach: minimum nodes based on average utilization (150% safety margin), maximum nodes based on peak utilization (150% safety margin). This ensures cost-effective baseline capacity while maintaining ceiling for traffic spikes. Safety margins are configurable via MIN_NODE_SAFETY_MARGIN_PERCENT and MAX_NODE_SAFETY_MARGIN_PERCENT.
    [Tags]    Azure    Cost Optimization    AKS    Kubernetes    Node Pools    Autoscaling    Capacity Planning    access:read-only    data:config
    ${aks_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_aks_node_pool_optimization.sh
    ...    env=${env}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${aks_analysis.stdout}

    # Generate summary statistics for AKS optimization
    ${aks_summary_cmd}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "aks_node_pool_optimization_issues.json" ]; then echo "AKS Node Pool Optimization Summary:"; echo "===================================="; jq -r 'group_by(.severity) | map({severity: .[0].severity, count: length}) | sort_by(.severity) | .[] | "Severity \\(.severity): \\(.count) issue(s)"' aks_node_pool_optimization_issues.json; echo ""; echo "Top Optimization Opportunities:"; jq -r 'sort_by(.severity) | limit(5; .[]) | "- \\(.title)"' aks_node_pool_optimization_issues.json; else echo "No AKS optimization data available"; fi
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false
    
    RW.Core.Add Pre To Report    ${aks_summary_cmd.stdout}
    
    # Extract detailed AKS analysis report
    ${aks_details}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "aks_node_pool_optimization_report.txt" ]; then echo ""; echo "Detailed AKS Optimization Report:"; echo "=================================="; tail -30 aks_node_pool_optimization_report.txt; else echo "No detailed AKS report available"; fi
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false
    
    RW.Core.Add Pre To Report    ${aks_details.stdout}

    ${aks_issues}=    RW.CLI.Run Cli
    ...    cmd=cat aks_node_pool_optimization_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ${aks_issue_list}=    Evaluate    json.loads(r'''${aks_issues.stdout}''')    json
    IF    len(@{aks_issue_list}) > 0 
        FOR    ${issue}    IN    @{aks_issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=AKS node pools should be right-sized based on actual utilization to minimize costs while maintaining performance
            ...    actual=AKS node pool optimization opportunities identified with potential savings from reducing node counts or changing VM types
            ...    title=${issue["title"]}
            ...    reproduce_hint=${aks_analysis.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_step"]}
        END
    ELSE
        RW.Core.Add Pre To Report    ✅ No AKS node pool optimization opportunities found. All node pools appear to be efficiently sized.
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
    ...    description=Comma-separated list of Azure subscription IDs to analyze for AKS optimization.
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
    ${COST_ANALYSIS_LOOKBACK_DAYS}=    RW.Core.Import User Variable    COST_ANALYSIS_LOOKBACK_DAYS
    ...    type=string
    ...    description=Number of days to look back for utilization analysis (default: 30)
    ...    pattern=\d+
    ...    default=30
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
    ${AZURE_DISCOUNT_PERCENTAGE}=    RW.Core.Import User Variable    AZURE_DISCOUNT_PERCENTAGE
    ...    type=string
    ...    description=Discount percentage off MSRP for Azure services (default: 0)
    ...    pattern=\d+
    ...    default=0
    ${TIMEOUT_SECONDS}=    RW.Core.Import User Variable    TIMEOUT_SECONDS
    ...    type=string
    ...    description=Timeout in seconds for tasks (default: 1500 = 25 minutes).
    ...    pattern=\d+
    ...    default=1500
    
    Set Suite Variable    ${AZURE_SUBSCRIPTION_IDS}    ${AZURE_SUBSCRIPTION_IDS}
    Set Suite Variable    ${AZURE_RESOURCE_GROUPS}    ${AZURE_RESOURCE_GROUPS}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_NAME}    ${AZURE_SUBSCRIPTION_NAME}
    Set Suite Variable    ${COST_ANALYSIS_LOOKBACK_DAYS}    ${COST_ANALYSIS_LOOKBACK_DAYS}
    Set Suite Variable    ${LOW_COST_THRESHOLD}    ${LOW_COST_THRESHOLD}
    Set Suite Variable    ${MEDIUM_COST_THRESHOLD}    ${MEDIUM_COST_THRESHOLD}
    Set Suite Variable    ${HIGH_COST_THRESHOLD}    ${HIGH_COST_THRESHOLD}
    Set Suite Variable    ${AZURE_DISCOUNT_PERCENTAGE}    ${AZURE_DISCOUNT_PERCENTAGE}
    Set Suite Variable    ${TIMEOUT_SECONDS}    ${TIMEOUT_SECONDS}
    
    ${env}=    Create Dictionary
    ...    AZURE_SUBSCRIPTION_IDS=${AZURE_SUBSCRIPTION_IDS}
    ...    AZURE_RESOURCE_GROUPS=${AZURE_RESOURCE_GROUPS}
    ...    COST_ANALYSIS_LOOKBACK_DAYS=${COST_ANALYSIS_LOOKBACK_DAYS}
    ...    LOW_COST_THRESHOLD=${LOW_COST_THRESHOLD}
    ...    MEDIUM_COST_THRESHOLD=${MEDIUM_COST_THRESHOLD}
    ...    HIGH_COST_THRESHOLD=${HIGH_COST_THRESHOLD}
    ...    AZURE_DISCOUNT_PERCENTAGE=${AZURE_DISCOUNT_PERCENTAGE}
    Set Suite Variable    ${env}

