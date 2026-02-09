*** Settings ***
Documentation       Azure VM Cost Optimization: Analyzes Virtual Machines to identify cost optimization opportunities including stopped-but-not-deallocated VMs and oversized VMs with low utilization that can be rightsized to burstable B-series instances.
Metadata            Author    stewartshea
Metadata            Display Name    Azure VM Cost Optimization
Metadata            Supports    Azure    Cost Optimization    Virtual Machines    VMs    Rightsizing    Deallocation
Force Tags          Azure    Cost Optimization    Virtual Machines    Rightsizing

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             Collections
Suite Setup         Suite Initialization


*** Tasks ***
Analyze Virtual Machine Rightsizing and Deallocation Opportunities in Resource Group `${AZURE_RESOURCE_GROUPS}` for Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Analyzes Azure Virtual Machines across specified subscriptions to identify cost optimization opportunities. Focuses on: 1) VMs that are stopped but not deallocated (still incurring compute costs), 2) Oversized VMs with low CPU utilization that can be downsized to B-series burstable instances. Examines CPU utilization metrics over the past 30 days to provide data-driven rightsizing recommendations.
    [Tags]    Azure    Cost Optimization    Virtual Machines    VMs    Rightsizing    Deallocation    access:read-only
    ${vm_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_vm_optimization.sh
    ...    env=${env}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${vm_analysis.stdout}

    # Generate summary statistics for VM optimization
    ${vm_summary_cmd}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "vm_optimization_issues.json" ]; then echo "Virtual Machine Optimization Summary:"; echo "====================================="; jq -r 'group_by(.severity) | map({severity: .[0].severity, count: length}) | sort_by(.severity) | .[] | "Severity \\(.severity): \\(.count) issue(s)"' vm_optimization_issues.json; echo ""; echo "Top Optimization Opportunities:"; jq -r 'sort_by(.severity) | limit(5; .[]) | "- \\(.title)"' vm_optimization_issues.json; else echo "No VM optimization data available"; fi
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false
    
    RW.Core.Add Pre To Report    ${vm_summary_cmd.stdout}
    
    # Extract detailed VM analysis report
    ${vm_details}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "vm_optimization_report.txt" ]; then echo ""; echo "Detailed VM Optimization Report:"; echo "================================"; tail -30 vm_optimization_report.txt; else echo "No detailed VM report available"; fi
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false
    
    RW.Core.Add Pre To Report    ${vm_details.stdout}

    ${vm_issues}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "vm_optimization_issues.json" ] && [ -s "vm_optimization_issues.json" ]; then cat vm_optimization_issues.json; else echo "[]"; fi
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ${issues_stdout}=    Set Variable If    "${vm_issues.stdout}" == ""    []    ${vm_issues.stdout}
    ${vm_issue_list}=    Evaluate    json.loads(r'''${issues_stdout}''')    json
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
        ...    timeout_seconds=300
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
        ...    title=Azure VM Optimization: ${issue_count} VMs Can Save $${monthly_savings}/Month in `${AZURE_SUBSCRIPTION_NAME}`
        ...    reproduce_hint=${vm_analysis.cmd}
        ...    details=${consolidated_details}
        ...    next_steps=${consolidated_next_steps.stdout}
    ELSE
        RW.Core.Add Pre To Report    ✅ No VM optimization opportunities found. All VMs appear to be properly deallocated and sized.
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
    ...    description=Comma-separated list of Azure subscription IDs to analyze for VM optimization.
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
    ...    description=Monthly savings threshold for LOW classification (default: 0)
    ...    pattern=\d+
    ...    default=0
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
