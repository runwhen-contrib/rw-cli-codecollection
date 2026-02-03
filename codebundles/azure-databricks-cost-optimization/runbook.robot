*** Settings ***
Documentation       Azure Databricks Cost Optimization: Analyzes Databricks workspaces and clusters to identify cost optimization opportunities including clusters without auto-termination, idle running clusters, and over-provisioned clusters with low utilization.
Metadata            Author    stewartshea
Metadata            Display Name    Azure Databricks Cost Optimization
Metadata            Supports    Azure    Cost Optimization    Databricks    Spark    Clusters    Auto-Termination
Force Tags          Azure    Cost Optimization    Databricks    Spark    Clusters

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             Collections
Suite Setup         Suite Initialization


*** Tasks ***
Analyze Databricks Cluster Auto-Termination and Over-Provisioning Opportunities for Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Analyzes Azure Databricks workspaces and clusters across specified subscriptions to identify cost optimization opportunities. Focuses on: 1) Clusters without auto-termination configured or running idle, 2) Over-provisioned clusters with low CPU/memory utilization. Calculates both VM costs and DBU (Databricks Unit) costs to provide accurate savings estimates.
    [Tags]    Azure    Cost Optimization    Databricks    Spark    Clusters    Auto-Termination    access:read-only
    ${databricks_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_databricks_cluster_optimization.sh
    ...    env=${env}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${databricks_analysis.stdout}

    # Generate summary statistics for Databricks optimization
    ${databricks_summary_cmd}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "databricks_cluster_optimization_issues.json" ]; then echo "Databricks Cluster Optimization Summary:"; echo "========================================="; jq -r 'group_by(.severity) | map({severity: .[0].severity, count: length}) | sort_by(.severity) | .[] | "Severity \\(.severity): \\(.count) issue(s)"' databricks_cluster_optimization_issues.json; echo ""; echo "Top Optimization Opportunities:"; jq -r 'sort_by(.severity) | limit(5; .[]) | "- \\(.title)"' databricks_cluster_optimization_issues.json; else echo "No Databricks optimization data available"; fi
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false
    
    RW.Core.Add Pre To Report    ${databricks_summary_cmd.stdout}
    
    # Extract detailed Databricks analysis report
    ${databricks_details}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "databricks_cluster_optimization_report.txt" ]; then echo ""; echo "Detailed Databricks Optimization Report:"; echo "========================================"; tail -30 databricks_cluster_optimization_report.txt; else echo "No detailed Databricks report available"; fi
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false
    
    RW.Core.Add Pre To Report    ${databricks_details.stdout}

    ${databricks_issues}=    RW.CLI.Run Cli
    ...    cmd=cat databricks_cluster_optimization_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ${databricks_issue_list}=    Evaluate    json.loads(r'''${databricks_issues.stdout}''')    json
    IF    len(@{databricks_issue_list}) > 0 
        FOR    ${issue}    IN    @{databricks_issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=Databricks clusters should have auto-termination configured and be right-sized based on actual utilization to minimize costs
            ...    actual=Databricks cluster optimization opportunities identified with potential savings from enabling auto-termination, terminating idle clusters, or reducing cluster size
            ...    title=${issue["title"]}
            ...    reproduce_hint=${databricks_analysis.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_step"]}
        END
    ELSE
        RW.Core.Add Pre To Report    ✅ No Databricks cluster optimization opportunities found. All clusters have proper auto-termination and appear well-utilized.
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
    ...    description=Comma-separated list of Azure subscription IDs to analyze for Databricks optimization.
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
