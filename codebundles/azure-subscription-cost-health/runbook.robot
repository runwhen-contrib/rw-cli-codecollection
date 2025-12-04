*** Settings ***
Documentation       Comprehensive Azure cost management toolkit: generate historical cost reports by service/resource group, analyze subscription cost health by identifying stopped functions on App Service Plans, propose consolidation opportunities, analyze AKS node pool utilization, analyze Databricks cluster auto-termination and over-provisioning, identify VM deallocation and rightsizing opportunities, analyze storage cost optimization (orphaned disks, old snapshots, lifecycle policies, redundancy), and estimate potential cost savings with configurable discount factors
Metadata            Author    assistant
Metadata            Display Name    Azure Subscription Cost Health & Reporting
Metadata            Supports    Azure    Cost Optimization    Cost Management    Cost Reporting    Function Apps    App Service Plans    AKS    Kubernetes    Databricks    Spark    Virtual Machines    Storage    Managed Disks    Snapshots    Blob Storage
Force Tags          Azure    Cost Optimization    Cost Management    Function Apps    App Service Plans    AKS    Databricks    Virtual Machines    Storage

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             Collections
Suite Setup         Suite Initialization


*** Tasks ***
Generate Azure Cost Report By Service and Resource Group
    [Documentation]    Generates a detailed cost breakdown report for the last 30 days showing actual spending by resource group and Azure service using the Cost Management API. Includes period-over-period comparison and raises an issue if cost increase exceeds configured threshold.
    [Tags]    Azure    Cost Analysis    Cost Management    Reporting    Trend Analysis    access:read-only
    ${cost_report}=    RW.CLI.Run Bash File
    ...    bash_file=azure_cost_historical_report.sh
    ...    env=${env}
    ...    timeout_seconds=600
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${cost_report.stdout}
    RW.Core.Add Pre To Report    ${cost_report.stderr}
    
    # Check for cost trend issues
    ${trend_issues}=    RW.CLI.Run Cli
    ...    cmd=cat azure_cost_trend_issues.json
    ...    env=${env}
    ...    timeout_seconds=30
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

Analyze App Service Plan Cost Optimization
    [Documentation]    Analyzes App Service Plans across subscriptions to identify empty plans, underutilized resources, and rightsizing opportunities with cost savings estimates. Supports three optimization strategies (aggressive/balanced/conservative) and provides comprehensive options tables with risk assessments for each plan.
    [Tags]    Azure    Cost Optimization    App Service Plans    Function Apps    Web Apps    Rightsizing    access:read-only
    ${cost_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=azure_appservice_cost_optimization.sh
    ...    env=${env}
    ...    timeout_seconds=600
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${cost_analysis.stdout}

    # Generate summary statistics
    ${summary_cmd}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "azure_appservice_cost_optimization_issues.json" ]; then echo "Cost Health Analysis Summary:"; echo "============================"; jq -r 'group_by(.severity) | map({severity: .[0].severity, count: length}) | sort_by(.severity) | .[] | "Severity \\(.severity): \\(.count) issue(s)"' azure_appservice_cost_optimization_issues.json; echo ""; echo "Top Cost Savings Opportunities:"; jq -r 'sort_by(.severity) | limit(5; .[]) | "- \\(.title)"' azure_appservice_cost_optimization_issues.json; else echo "No cost analysis data available"; fi
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    
    RW.Core.Add Pre To Report    ${summary_cmd.stdout}
    
    # Extract potential savings totals if available
    ${savings_summary}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "azure_appservice_cost_optimization_report.txt" ]; then echo ""; echo "Detailed Analysis Report:"; echo "========================"; tail -20 azure_appservice_cost_optimization_report.txt; else echo "No detailed report available"; fi
    ...    env=${env}
    ...    timeout_seconds=30
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
    ...    cmd=if [ -f "aks_node_pool_optimization_issues.json" ]; then echo "AKS Node Pool Optimization Summary:"; echo "===================================="; jq -r 'group_by(.severity) | map({severity: .[0].severity, count: length}) | sort_by(.severity) | .[] | "Severity \\(.severity): \\(.count) issue(s)"' aks_node_pool_optimization_issues.json; echo ""; echo "Top Optimization Opportunities:"; jq -r 'sort_by(.severity) | limit(5; .[]) | "- \\(.title)"' aks_node_pool_optimization_issues.json; else echo "No AKS optimization data available"; fi
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

Analyze Databricks Cluster Auto-Termination and Over-Provisioning Opportunities
    [Documentation]    Analyzes Azure Databricks workspaces and clusters across specified subscriptions to identify cost optimization opportunities. Focuses on: 1) Clusters without auto-termination configured or running idle, 2) Over-provisioned clusters with low CPU/memory utilization. Calculates both VM costs and DBU (Databricks Unit) costs to provide accurate savings estimates.
    [Tags]    Azure    Cost Optimization    Databricks    Spark    Clusters    Auto-Termination    access:read-only
    ${databricks_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_databricks_cluster_optimization.sh
    ...    env=${env}
    ...    timeout_seconds=900
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${databricks_analysis.stdout}

    # Generate summary statistics for Databricks optimization
    ${databricks_summary_cmd}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "databricks_cluster_optimization_issues.json" ]; then echo "Databricks Cluster Optimization Summary:"; echo "========================================="; jq -r 'group_by(.severity) | map({severity: .[0].severity, count: length}) | sort_by(.severity) | .[] | "Severity \\(.severity): \\(.count) issue(s)"' databricks_cluster_optimization_issues.json; echo ""; echo "Top Optimization Opportunities:"; jq -r 'sort_by(.severity) | limit(5; .[]) | "- \\(.title)"' databricks_cluster_optimization_issues.json; else echo "No Databricks optimization data available"; fi
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    
    RW.Core.Add Pre To Report    ${databricks_summary_cmd.stdout}
    
    # Extract detailed Databricks analysis report
    ${databricks_details}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "databricks_cluster_optimization_report.txt" ]; then echo ""; echo "Detailed Databricks Optimization Report:"; echo "========================================"; tail -30 databricks_cluster_optimization_report.txt; else echo "No detailed Databricks report available"; fi
    ...    env=${env}
    ...    timeout_seconds=30
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

Analyze Virtual Machine Rightsizing and Deallocation Opportunities
    [Documentation]    Analyzes Azure Virtual Machines across specified subscriptions to identify cost optimization opportunities. Focuses on: 1) VMs that are stopped but not deallocated (still incurring compute costs), 2) Oversized VMs with low CPU utilization that can be downsized to B-series burstable instances. Examines CPU utilization metrics over the past 30 days to provide data-driven rightsizing recommendations.
    [Tags]    Azure    Cost Optimization    Virtual Machines    VMs    Rightsizing    Deallocation    access:read-only
    ${vm_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_vm_optimization.sh
    ...    env=${env}
    ...    timeout_seconds=900
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${vm_analysis.stdout}

    # Generate summary statistics for VM optimization
    ${vm_summary_cmd}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "vm_optimization_issues.json" ]; then echo "Virtual Machine Optimization Summary:"; echo "====================================="; jq -r 'group_by(.severity) | map({severity: .[0].severity, count: length}) | sort_by(.severity) | .[] | "Severity \\(.severity): \\(.count) issue(s)"' vm_optimization_issues.json; echo ""; echo "Top Optimization Opportunities:"; jq -r 'sort_by(.severity) | limit(5; .[]) | "- \\(.title)"' vm_optimization_issues.json; else echo "No VM optimization data available"; fi
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    
    RW.Core.Add Pre To Report    ${vm_summary_cmd.stdout}
    
    # Extract detailed VM analysis report
    ${vm_details}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "vm_optimization_report.txt" ]; then echo ""; echo "Detailed VM Optimization Report:"; echo "================================"; tail -30 vm_optimization_report.txt; else echo "No detailed VM report available"; fi
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    
    RW.Core.Add Pre To Report    ${vm_details.stdout}

    ${vm_issues}=    RW.CLI.Run Cli
    ...    cmd=cat vm_optimization_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ${vm_issue_list}=    Evaluate    json.loads(r'''${vm_issues.stdout}''')    json
    IF    len(@{vm_issue_list}) > 0
        ${issue_count}=    Evaluate    len(@{vm_issue_list})
        
        # Calculate aggregate metrics using simpler approach - extract from each issue title
        ${total_savings}=    Set Variable    0.0
        FOR    ${issue}    IN    @{vm_issue_list}
            ${title_with_amount}=    Set Variable    ${issue["title"]}
            # Try to extract amount using Python regex
            ${amount_str}=    Evaluate    __import__('re').search(r'\\$([0-9,]+\\.?[0-9]*)', '''${title_with_amount}''').group(1) if __import__('re').search(r'\\$([0-9,]+\\.?[0-9]*)', '''${title_with_amount}''') else "0"
            ${amount_clean}=    Evaluate    float('''${amount_str}'''.replace(',', ''))
            ${total_savings}=    Evaluate    ${total_savings} + ${amount_clean}
        END
        
        ${monthly_savings}=    Evaluate    round(${total_savings}, 2)
        ${annual_savings}=    Evaluate    round(float('${monthly_savings}') * 12, 2)
        
        # Build consolidated details with ALL VM specifics
        ${separator}=    Set Variable    ──────────────────────────────────────────────────────────────────────
        ${header_text}=    Set Variable    VIRTUAL MACHINE OPTIMIZATION OPPORTUNITIES\n\nTotal Opportunities: ${issue_count} VMs\nMonthly Savings: $${monthly_savings}\nAnnual Savings: $${annual_savings}\n\n════════════════════════════════════════════════════════════════════\nSPECIFIC VM RECOMMENDATIONS (sorted by savings):\n════════════════════════════════════════════════════════════════════\n
        
        # Build VM details from the issue list
        ${vm_details_text}=    Set Variable    ${EMPTY}
        FOR    ${issue}    IN    @{vm_issue_list}
            ${vm_details_text}=    Set Variable    ${vm_details_text}\n${issue["title"]}\n${separator}\n${issue["details"]}\n\nACTION:\n${issue["next_step"]}\n\n
        END
        
        ${consolidated_details}=    Set Variable    ${header_text}${vm_details_text}
        
        ${consolidated_next_steps}=    RW.CLI.Run Cli
        ...    cmd=echo "PRIORITIZED ACTION PLAN:"; echo ""; echo "1. Review all ${issue_count} VM recommendations above"; echo "2. Start with highest-savings VMs first"; echo "3. For each VM:"; echo "a. Verify current utilization matches analysis"; echo "b. Test resize in dev/test first if available"; echo "c. Execute resize command during maintenance window"; echo "d. Monitor for 24-48 hours post-resize"; echo ""; echo "NOTE: All B-series recommendations are burstable instances."; echo "They provide baseline performance with ability to burst to 100% CPU when needed."; echo "Ideal for workloads with low average CPU but occasional spikes."
        ...    env=${env}
        ...    timeout_seconds=30
        ...    include_in_history=false
        
        # Determine severity based on total savings
        ${severity}=    Set Variable If    ${monthly_savings} >= 2000    2
        ...    ${monthly_savings} >= 500    3
        ...    4
        
        # Create ONE consolidated issue with all VM details
        RW.Core.Add Issue
        ...    severity=${severity}
        ...    expected=Virtual Machines should be deallocated when stopped and right-sized based on actual utilization to minimize costs
        ...    actual=Found ${issue_count} oversized or stopped-not-deallocated VMs with total potential savings of $${monthly_savings}/month ($${annual_savings}/year)
        ...    title=Azure VM Optimization: ${issue_count} VMs Can Save $${monthly_savings}/Month
        ...    reproduce_hint=${vm_analysis.cmd}
        ...    details=${consolidated_details}
        ...    next_steps=${consolidated_next_steps.stdout}
    ELSE
        RW.Core.Add Pre To Report    ✅ No VM optimization opportunities found. All VMs appear to be properly deallocated and sized.
    END

Analyze Azure Storage Cost Optimization Opportunities
    [Documentation]    Analyzes Azure storage resources across specified subscriptions to identify cost optimization opportunities. Focuses on: 1) Unattached/orphaned managed disks still incurring costs, 2) Old snapshots (>90 days by default) consuming storage, 3) Storage accounts without lifecycle management policies, 4) Over-provisioned redundancy (GRS/GZRS that could use LRS/ZRS), 5) Premium disks with low IOPS utilization that could be downgraded to Standard SSD.
    [Tags]    Azure    Cost Optimization    Storage    Managed Disks    Snapshots    Blob Storage    Lifecycle Management    access:read-only
    ${storage_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_storage_optimization.sh
    ...    env=${env}
    ...    timeout_seconds=900
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${storage_analysis.stdout}

    # Generate summary statistics for Storage optimization
    ${storage_summary_cmd}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "storage_optimization_issues.json" ]; then echo "Storage Cost Optimization Summary:"; echo "==================================="; jq -r 'group_by(.severity) | map({severity: .[0].severity, count: length}) | sort_by(.severity) | .[] | "Severity \\(.severity): \\(.count) issue(s)"' storage_optimization_issues.json; echo ""; echo "Top Optimization Opportunities:"; jq -r 'sort_by(.severity) | limit(5; .[]) | "- \\(.title)"' storage_optimization_issues.json; else echo "No storage optimization data available"; fi
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    
    RW.Core.Add Pre To Report    ${storage_summary_cmd.stdout}
    
    # Extract detailed Storage analysis report
    ${storage_details}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "storage_optimization_report.txt" ]; then echo ""; echo "Detailed Storage Optimization Report:"; echo "====================================="; tail -40 storage_optimization_report.txt; else echo "No detailed storage report available"; fi
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    
    RW.Core.Add Pre To Report    ${storage_details.stdout}

    ${storage_issues}=    RW.CLI.Run Cli
    ...    cmd=cat storage_optimization_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ${storage_issue_list}=    Evaluate    json.loads(r'''${storage_issues.stdout}''')    json
    IF    len(@{storage_issue_list}) > 0 
        FOR    ${issue}    IN    @{storage_issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=Storage resources should be properly managed with lifecycle policies, appropriate redundancy, and no orphaned resources
            ...    actual=Storage optimization opportunities identified with potential savings from cleaning up orphaned disks/snapshots, configuring lifecycle policies, or optimizing redundancy settings
            ...    title=${issue["title"]}
            ...    reproduce_hint=${storage_analysis.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_step"]}
        END
    ELSE
        RW.Core.Add Pre To Report    ✅ No storage optimization opportunities found. All storage resources appear to be efficiently managed.
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
    ...    description=Comma-separated list of Azure subscription IDs to analyze for cost optimization (e.g., "sub1,sub2,sub3"). Leave empty to use current subscription.
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
    ...    description=Number of days to look back for cost and utilization analysis (default: 30)
    ...    pattern=\d+
    ...    default=30
    ${LOW_COST_THRESHOLD}=    RW.Core.Import User Variable    LOW_COST_THRESHOLD
    ...    type=string
    ...    description=Reserved for future use. Recommendations with savings < MEDIUM_COST_THRESHOLD are automatically classified as LOW Savings (default: 0)
    ...    pattern=\d+
    ...    default=0
    ${MEDIUM_COST_THRESHOLD}=    RW.Core.Import User Variable    MEDIUM_COST_THRESHOLD
    ...    type=string
    ...    description=Monthly savings threshold in USD for MEDIUM savings classification. Recommendations with savings >= this value but < HIGH_COST_THRESHOLD are grouped as MEDIUM Savings (default: 2000)
    ...    pattern=\d+
    ...    default=2000
    ${HIGH_COST_THRESHOLD}=    RW.Core.Import User Variable    HIGH_COST_THRESHOLD
    ...    type=string
    ...    description=Monthly savings threshold in USD for HIGH savings classification. Recommendations with savings >= this value are grouped as HIGH Savings (default: 10000)
    ...    pattern=\d+
    ...    default=10000
    ${AZURE_DISCOUNT_PERCENTAGE}=    RW.Core.Import User Variable    AZURE_DISCOUNT_PERCENTAGE
    ...    type=string
    ...    description=Discount percentage off MSRP for Azure services (e.g., 20 for 20% discount, default: 0)
    ...    pattern=\d+
    ...    default=0
    ${OPTIMIZATION_STRATEGY}=    RW.Core.Import User Variable    OPTIMIZATION_STRATEGY
    ...    type=string
    ...    description=App Service Plan optimization strategy: 'aggressive' (max savings, 85-90% target CPU, dev/test), 'balanced' (default, 75-80% target CPU, standard prod), or 'conservative' (safest, 60-70% target CPU, critical prod)
    ...    pattern=(aggressive|balanced|conservative)
    ...    default=balanced
    ${COST_INCREASE_THRESHOLD}=    RW.Core.Import User Variable    COST_INCREASE_THRESHOLD
    ...    type=string
    ...    description=Percentage threshold for cost increase alerts. An issue will be raised if period-over-period cost increase exceeds this value (e.g., 10 for 10% increase, default: 10)
    ...    pattern=\d+
    ...    default=10
    ${SNAPSHOT_AGE_THRESHOLD_DAYS}=    RW.Core.Import User Variable    SNAPSHOT_AGE_THRESHOLD_DAYS
    ...    type=string
    ...    description=Age threshold in days for identifying old snapshots that may be candidates for deletion (default: 90)
    ...    pattern=\d+
    ...    default=90
    
    # Set suite variables
    Set Suite Variable    ${AZURE_SUBSCRIPTION_IDS}    ${AZURE_SUBSCRIPTION_IDS}
    Set Suite Variable    ${AZURE_RESOURCE_GROUPS}    ${AZURE_RESOURCE_GROUPS}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_NAME}    ${AZURE_SUBSCRIPTION_NAME}
    Set Suite Variable    ${COST_ANALYSIS_LOOKBACK_DAYS}    ${COST_ANALYSIS_LOOKBACK_DAYS}
    Set Suite Variable    ${LOW_COST_THRESHOLD}    ${LOW_COST_THRESHOLD}
    Set Suite Variable    ${MEDIUM_COST_THRESHOLD}    ${MEDIUM_COST_THRESHOLD}
    Set Suite Variable    ${HIGH_COST_THRESHOLD}    ${HIGH_COST_THRESHOLD}
    Set Suite Variable    ${AZURE_DISCOUNT_PERCENTAGE}    ${AZURE_DISCOUNT_PERCENTAGE}
    Set Suite Variable    ${OPTIMIZATION_STRATEGY}    ${OPTIMIZATION_STRATEGY}
    Set Suite Variable    ${COST_INCREASE_THRESHOLD}    ${COST_INCREASE_THRESHOLD}
    Set Suite Variable    ${SNAPSHOT_AGE_THRESHOLD_DAYS}    ${SNAPSHOT_AGE_THRESHOLD_DAYS}
    
    # Create environment variables for the bash script
    ${env}=    Create Dictionary
    ...    AZURE_SUBSCRIPTION_IDS=${AZURE_SUBSCRIPTION_IDS}
    ...    AZURE_RESOURCE_GROUPS=${AZURE_RESOURCE_GROUPS}
    ...    COST_ANALYSIS_LOOKBACK_DAYS=${COST_ANALYSIS_LOOKBACK_DAYS}
    ...    LOW_COST_THRESHOLD=${LOW_COST_THRESHOLD}
    ...    MEDIUM_COST_THRESHOLD=${MEDIUM_COST_THRESHOLD}
    ...    HIGH_COST_THRESHOLD=${HIGH_COST_THRESHOLD}
    ...    AZURE_DISCOUNT_PERCENTAGE=${AZURE_DISCOUNT_PERCENTAGE}
    ...    OPTIMIZATION_STRATEGY=${OPTIMIZATION_STRATEGY}
    ...    COST_INCREASE_THRESHOLD=${COST_INCREASE_THRESHOLD}
    ...    SNAPSHOT_AGE_THRESHOLD_DAYS=${SNAPSHOT_AGE_THRESHOLD_DAYS}
    Set Suite Variable    ${env}
    
    # Validate Azure CLI authentication and permissions
    ${auth_check}=    RW.CLI.Run Cli
    ...    cmd=az account show --query "{subscriptionId: id, subscriptionName: name, tenantId: tenantId, user: user.name}" -o table
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    
    Log    Current Azure Context: ${auth_check.stdout}
    
    # Validate access to target subscriptions
    ${subscription_validation}=    RW.CLI.Run Cli
    ...    cmd=if [ -n "$AZURE_SUBSCRIPTION_IDS" ]; then echo "Validating access to target subscriptions:"; for sub_id in $(echo "$AZURE_SUBSCRIPTION_IDS" | tr ',' ' '); do echo "Checking subscription: $sub_id"; az account show --subscription "$sub_id" --query "{id: id, name: name, state: state}" -o table 2>/dev/null || echo "❌ Cannot access subscription: $sub_id"; done; else echo "Using current subscription context"; az account show --query "{id: id, name: name, state: state}" -o table; fi
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
