*** Settings ***
Documentation       Azure Storage Cost Optimization: Analyzes storage resources to identify cost optimization opportunities including unattached disks, old snapshots, missing lifecycle policies, over-provisioned redundancy, and underutilized Premium disks.
Metadata            Author    stewartshea
Metadata            Display Name    Azure Storage Cost Optimization
Metadata            Supports    Azure    Cost Optimization    Storage    Managed Disks    Snapshots    Blob Storage    Lifecycle Management
Force Tags          Azure    Cost Optimization    Storage    Managed Disks    Snapshots

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             Collections
Suite Setup         Suite Initialization


*** Tasks ***
Analyze Azure Storage Cost Optimization Opportunities in Resource Group `${AZURE_RESOURCE_GROUPS}` for Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Analyzes Azure storage resources across specified subscriptions to identify cost optimization opportunities. Focuses on: 1) Unattached/orphaned managed disks still incurring costs, 2) Old snapshots (>90 days by default) consuming storage, 3) Storage accounts without lifecycle management policies, 4) Over-provisioned redundancy (GRS/GZRS that could use LRS/ZRS), 5) Premium disks with low IOPS utilization that could be downgraded to Standard SSD.
    [Tags]    Azure    Cost Optimization    Storage    Managed Disks    Snapshots    Blob Storage    Lifecycle Management    access:read-only
    ${storage_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_storage_optimization.sh
    ...    env=${env}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${storage_analysis.stdout}

    # Generate summary statistics for Storage optimization
    ${storage_summary_cmd}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "storage_optimization_issues.json" ]; then echo "Storage Cost Optimization Summary:"; echo "==================================="; jq -r 'group_by(.severity) | map({severity: .[0].severity, count: length}) | sort_by(.severity) | .[] | "Severity \\(.severity): \\(.count) issue(s)"' storage_optimization_issues.json; echo ""; echo "Top Optimization Opportunities:"; jq -r 'sort_by(.severity) | limit(5; .[]) | "- \\(.title)"' storage_optimization_issues.json; else echo "No storage optimization data available"; fi
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false
    
    RW.Core.Add Pre To Report    ${storage_summary_cmd.stdout}
    
    # Extract detailed Storage analysis report
    ${storage_details}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "storage_optimization_report.txt" ]; then echo ""; echo "Detailed Storage Optimization Report:"; echo "====================================="; tail -40 storage_optimization_report.txt; else echo "No detailed storage report available"; fi
    ...    env=${env}
    ...    timeout_seconds=300
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
    ...    description=Comma-separated list of Azure subscription IDs to analyze for storage optimization.
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
    ${SNAPSHOT_AGE_THRESHOLD_DAYS}=    RW.Core.Import User Variable    SNAPSHOT_AGE_THRESHOLD_DAYS
    ...    type=string
    ...    description=Age threshold in days for identifying old snapshots that may be candidates for deletion (default: 90)
    ...    pattern=\d+
    ...    default=90
    ${SCAN_MODE}=    RW.Core.Import User Variable    SCAN_MODE
    ...    type=string
    ...    description=Performance mode: 'full' (detailed, actual metrics), 'quick' (fast, estimates usage), 'sample' (analyze subset and extrapolate). Default: full
    ...    pattern=(quick|full|sample)
    ...    default=full
    ${MAX_PARALLEL_JOBS}=    RW.Core.Import User Variable    MAX_PARALLEL_JOBS
    ...    type=string
    ...    description=Maximum parallel jobs for metrics collection in full mode (default: 10)
    ...    pattern=\d+
    ...    default=10
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
    Set Suite Variable    ${SNAPSHOT_AGE_THRESHOLD_DAYS}    ${SNAPSHOT_AGE_THRESHOLD_DAYS}
    Set Suite Variable    ${SCAN_MODE}    ${SCAN_MODE}
    Set Suite Variable    ${MAX_PARALLEL_JOBS}    ${MAX_PARALLEL_JOBS}
    Set Suite Variable    ${TIMEOUT_SECONDS}    ${TIMEOUT_SECONDS}
    
    ${env}=    Create Dictionary
    ...    AZURE_SUBSCRIPTION_IDS=${AZURE_SUBSCRIPTION_IDS}
    ...    AZURE_RESOURCE_GROUPS=${AZURE_RESOURCE_GROUPS}
    ...    COST_ANALYSIS_LOOKBACK_DAYS=${COST_ANALYSIS_LOOKBACK_DAYS}
    ...    LOW_COST_THRESHOLD=${LOW_COST_THRESHOLD}
    ...    MEDIUM_COST_THRESHOLD=${MEDIUM_COST_THRESHOLD}
    ...    HIGH_COST_THRESHOLD=${HIGH_COST_THRESHOLD}
    ...    AZURE_DISCOUNT_PERCENTAGE=${AZURE_DISCOUNT_PERCENTAGE}
    ...    SNAPSHOT_AGE_THRESHOLD_DAYS=${SNAPSHOT_AGE_THRESHOLD_DAYS}
    ...    SCAN_MODE=${SCAN_MODE}
    ...    MAX_PARALLEL_JOBS=${MAX_PARALLEL_JOBS}
    Set Suite Variable    ${env}
