*** Settings ***
Documentation       Analyze Azure subscription cost health by identifying stopped functions on App Service Plans, proposing consolidation opportunities, analyzing AKS node pool utilization, and estimating potential cost savings with configurable discount factors
Metadata            Author    assistant
Metadata            Display Name    Azure Subscription Cost Health
Metadata            Supports    Azure    Cost Optimization    Function Apps    App Service Plans    AKS    Kubernetes
Force Tags          Azure    Cost Optimization    Function Apps    App Service Plans    AKS

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             Collections
Suite Setup         Suite Initialization


*** Tasks ***
Analyze Azure Subscription Cost Health for Stopped Functions and Consolidation Opportunities
    [Documentation]    Discovers stopped Function Apps on App Service Plans across specified subscriptions and resource groups, analyzes consolidation opportunities, and provides cost savings estimates with Azure pricing
    [Tags]    Azure    Cost Optimization    Function Apps    App Service Plans    Consolidation    access:read-only
    ${cost_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=azure_subscription_cost_analysis.sh
    ...    env=${env}
    ...    timeout_seconds=600
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${cost_analysis.stdout}

    # Generate summary statistics
    ${summary_cmd}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "azure_subscription_cost_analysis_issues.json" ]; then echo "Cost Health Analysis Summary:"; echo "============================"; jq -r 'group_by(.severity) | map({severity: .[0].severity, count: length}) | sort_by(.severity) | .[] | "Severity \(.severity): \(.count) issue(s)"' azure_subscription_cost_analysis_issues.json; echo ""; echo "Top Cost Savings Opportunities:"; jq -r 'sort_by(.severity) | limit(5; .[]) | "- \(.title)"' azure_subscription_cost_analysis_issues.json; else echo "No cost analysis data available"; fi
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    
    RW.Core.Add Pre To Report    ${summary_cmd.stdout}
    
    # Extract potential savings totals if available
    ${savings_summary}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "azure_subscription_cost_analysis_report.txt" ]; then echo ""; echo "Detailed Analysis Report:"; echo "========================"; tail -20 azure_subscription_cost_analysis_report.txt; else echo "No detailed report available"; fi
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    
    RW.Core.Add Pre To Report    ${savings_summary.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat azure_subscription_cost_analysis_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0 
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=Azure resources should be efficiently utilized to minimize costs and eliminate waste
            ...    actual=Cost optimization opportunities identified in Azure subscription with potential savings from stopped functions and consolidation
            ...    title=${issue["title"]}
            ...    reproduce_hint=${cost_analysis.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_step"]}
        END
    ELSE
        RW.Core.Add Pre To Report    ✅ No significant cost optimization opportunities found. All App Service Plans appear to be efficiently utilized.
    END

Analyze AKS Node Pool Resizing Opportunities Based on Utilization Metrics
    [Documentation]    Analyzes AKS cluster node pools across specified subscriptions, examines both average and peak CPU/memory utilization over the past 30 days, and provides capacity-planned recommendations for reducing minimum node counts or changing VM types to optimize costs. Uses a two-tier approach: minimum nodes based on average utilization (150% safety margin), maximum nodes based on peak utilization (150% safety margin). This ensures cost-effective baseline capacity while maintaining ceiling for traffic spikes. Safety margins are configurable via MIN_NODE_SAFETY_MARGIN_PERCENT and MAX_NODE_SAFETY_MARGIN_PERCENT.
    [Tags]    Azure    Cost Optimization    AKS    Kubernetes    Node Pools    Autoscaling    Capacity Planning    access:read-only
    ${aks_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_aks_node_pool_optimization.sh
    ...    env=${env}
    ...    timeout_seconds=900
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${aks_analysis.stdout}

    # Generate summary statistics for AKS optimization
    ${aks_summary_cmd}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "aks_node_pool_optimization_issues.json" ]; then echo "AKS Node Pool Optimization Summary:"; echo "===================================="; jq -r 'group_by(.severity) | map({severity: .[0].severity, count: length}) | sort_by(.severity) | .[] | "Severity \(.severity): \(.count) issue(s)"' aks_node_pool_optimization_issues.json; echo ""; echo "Top Optimization Opportunities:"; jq -r 'sort_by(.severity) | limit(5; .[]) | "- \(.title)"' aks_node_pool_optimization_issues.json; else echo "No AKS optimization data available"; fi
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    
    RW.Core.Add Pre To Report    ${aks_summary_cmd.stdout}
    
    # Extract detailed AKS analysis report
    ${aks_details}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "aks_node_pool_optimization_report.txt" ]; then echo ""; echo "Detailed AKS Optimization Report:"; echo "=================================="; tail -30 aks_node_pool_optimization_report.txt; else echo "No detailed AKS report available"; fi
    ...    env=${env}
    ...    timeout_seconds=30
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
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    ${AZURE_SUBSCRIPTION_IDS}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_IDS
    ...    type=string
    ...    description=Comma-separated list of Azure subscription IDs to analyze for cost optimization (e.g., "sub1,sub2,sub3")
    ...    pattern=[\w,-]*
    ...    default=""
    ${AZURE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=Single Azure subscription ID for backward compatibility (use AZURE_SUBSCRIPTION_IDS for multiple subscriptions)
    ...    pattern=\w*
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
    ...    description=Number of days to look back for cost and utilization analysis (default: 30)
    ...    pattern=\d+
    ...    default=30
    ${LOW_COST_THRESHOLD}=    RW.Core.Import User Variable    LOW_COST_THRESHOLD
    ...    type=string
    ...    description=Monthly cost threshold in USD for low severity issues (default: 500)
    ...    pattern=\d+
    ...    default=500
    ${MEDIUM_COST_THRESHOLD}=    RW.Core.Import User Variable    MEDIUM_COST_THRESHOLD
    ...    type=string
    ...    description=Monthly cost threshold in USD for medium severity issues (default: 2000)
    ...    pattern=\d+
    ...    default=2000
    ${HIGH_COST_THRESHOLD}=    RW.Core.Import User Variable    HIGH_COST_THRESHOLD
    ...    type=string
    ...    description=Monthly cost threshold in USD for high severity issues (default: 10000)
    ...    pattern=\d+
    ...    default=10000
    ${AZURE_DISCOUNT_PERCENTAGE}=    RW.Core.Import User Variable    AZURE_DISCOUNT_PERCENTAGE
    ...    type=string
    ...    description=Discount percentage off MSRP for Azure services (e.g., 20 for 20% discount, default: 0)
    ...    pattern=\d+
    ...    default=0
    
    # Set suite variables
    Set Suite Variable    ${AZURE_SUBSCRIPTION_IDS}    ${AZURE_SUBSCRIPTION_IDS}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUPS}    ${AZURE_RESOURCE_GROUPS}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_NAME}    ${AZURE_SUBSCRIPTION_NAME}
    Set Suite Variable    ${COST_ANALYSIS_LOOKBACK_DAYS}    ${COST_ANALYSIS_LOOKBACK_DAYS}
    Set Suite Variable    ${LOW_COST_THRESHOLD}    ${LOW_COST_THRESHOLD}
    Set Suite Variable    ${MEDIUM_COST_THRESHOLD}    ${MEDIUM_COST_THRESHOLD}
    Set Suite Variable    ${HIGH_COST_THRESHOLD}    ${HIGH_COST_THRESHOLD}
    Set Suite Variable    ${AZURE_DISCOUNT_PERCENTAGE}    ${AZURE_DISCOUNT_PERCENTAGE}
    
    # Create environment variables for the bash script
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_SUBSCRIPTION_IDS":"${AZURE_SUBSCRIPTION_IDS}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}", "AZURE_RESOURCE_GROUPS":"${AZURE_RESOURCE_GROUPS}", "COST_ANALYSIS_LOOKBACK_DAYS":"${COST_ANALYSIS_LOOKBACK_DAYS}", "LOW_COST_THRESHOLD":"${LOW_COST_THRESHOLD}", "MEDIUM_COST_THRESHOLD":"${MEDIUM_COST_THRESHOLD}", "HIGH_COST_THRESHOLD":"${HIGH_COST_THRESHOLD}", "AZURE_DISCOUNT_PERCENTAGE":"${AZURE_DISCOUNT_PERCENTAGE}"}
    
    # Validate Azure CLI authentication and permissions
    ${auth_check}=    RW.CLI.Run Cli
    ...    cmd=az account show --query "{subscriptionId: id, subscriptionName: name, tenantId: tenantId, user: user.name}" -o table
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    
    Log    Current Azure Context: ${auth_check.stdout}
    
    # Validate access to target subscriptions
    ${subscription_validation}=    RW.CLI.Run Cli
    ...    cmd=if [ -n "${AZURE_SUBSCRIPTION_IDS:-}" ]; then echo "Validating access to target subscriptions:"; for sub_id in $(echo "${AZURE_SUBSCRIPTION_IDS}" | tr ',' ' '); do echo "Checking subscription: $sub_id"; az account show --subscription "$sub_id" --query "{id: id, name: name, state: state}" -o table 2>/dev/null || echo "❌ Cannot access subscription: $sub_id"; done; elif [ -n "${AZURE_SUBSCRIPTION_ID:-}" ]; then echo "Validating access to subscription: ${AZURE_SUBSCRIPTION_ID}"; az account show --subscription "${AZURE_SUBSCRIPTION_ID}" --query "{id: id, name: name, state: state}" -o table; else echo "Using current subscription context"; fi
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    
    Log    Subscription Access Validation: ${subscription_validation.stdout}
    
    # Check required permissions
    ${permissions_check}=    RW.CLI.Run Cli
    ...    cmd=echo "Checking required permissions:"; echo "- App Service Plans: $(az provider show --namespace Microsoft.Web --query "registrationState" -o tsv 2>/dev/null || echo 'Not available')"; echo "- Function Apps: $(az functionapp list --query "length(@)" -o tsv 2>/dev/null && echo 'Access granted' || echo 'Access denied')"; echo "- Resource Groups: $(az group list --query "length(@)" -o tsv 2>/dev/null && echo 'Access granted' || echo 'Access denied')"; echo "- Monitor Metrics: $(az provider show --namespace Microsoft.Insights --query "registrationState" -o tsv 2>/dev/null || echo 'Not available')"
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    
    Log    Permission Check Results: ${permissions_check.stdout}

    # Set Azure subscription context if single subscription is provided
    IF    "${AZURE_SUBSCRIPTION_ID}" != ""
        RW.CLI.Run Cli
        ...    cmd=az account set --subscription ${AZURE_SUBSCRIPTION_ID}
        ...    include_in_history=false
    END
