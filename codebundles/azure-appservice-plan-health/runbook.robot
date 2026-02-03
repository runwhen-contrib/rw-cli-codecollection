*** Settings ***
Documentation       Check Azure App Service Plan health by identifying availability issues, high usage issues, and providing scaling recommendations 
Metadata            Author    saurabh3460
Metadata            Display Name    Azure    App Service Plan Health
Metadata            Supports    Azure    App Service Plan Health
Force Tags          Azure    App Service Plan Health

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             Collections
Library             DateTime
Suite Setup         Suite Initialization


*** Tasks ***
Check Azure App Service Plan Resource Health in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Check the Azure Resource Health API for any known issues affecting App Service Plans
    [Tags]    AppServicePlan    Azure    Health    access:read-only
    ${output}=    RW.CLI.Run Bash File
    ...    bash_file=asp-health-check.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat asp_health.json
    TRY
        ${health_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${health_list}=    Create List
    END
    IF    $health_list
        FOR    ${health}    IN    @{health_list}
            ${pretty_health}=    Evaluate    pprint.pformat(${health})    modules=pprint
            ${plan_name}=    Set Variable    ${health['resourceName']}
            ${health_status}=    Set Variable    ${health['properties']['availabilityState']}
            ${issue_timestamp}=    Set Variable    ${health['properties']['occuredTime']}
            IF    "${health_status}" != "Available"
                RW.Core.Add Issue
                ...    severity=3
                ...    expected=Azure App Service Plan `${plan_name}` should have health status of `Available` in resource group `${AZURE_RESOURCE_GROUP}` 
                ...    actual=Azure App Service Plan `${plan_name}` has health status of `${health_status}` in resource group `${AZURE_RESOURCE_GROUP}` 
                ...    title=Azure App Service Plan `${plan_name}` with Health Status of `${health_status}` found in Resource Group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    reproduce_hint=${output.cmd}
                ...    details={"health": ${pretty_health}, "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
                ...    next_steps=Investigate the health status of the Azure App Service Plan in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    observed_at=${issue_timestamp}
            END
        END
    ELSE
        ${issue_timestamp}=    Datetime.Get Current Date
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Azure App Service Plan health should be enabled in resource group `${AZURE_RESOURCE_GROUP}`
        ...    actual=Azure App Service Plan health appears unavailable in resource group `${AZURE_RESOURCE_GROUP}`
        ...    title=Azure resource health is unavailable for App Service Plan in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
        ...    reproduce_hint=${output.cmd}
        ...    details={"health_list": ${health_list}, "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
        ...    next_steps=Enable App Service Plan `${plan_name}` health provider Microsoft.ResourceHealth in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
        ...    observed_at=${issue_timestamp}
    END


Check App Service Plan Capacity and Recommendations in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Check App Service Plan capacity, report high usage issues, and provide scaling recommendations
    [Tags]    AppService    Azure    Capacity    Recommendations    access:read-only
    
    # Run the capacity check script with proper environment variables
    ${script_output}=    RW.CLI.Run Bash File
    ...    bash_file=check_appservice_plan_capacity.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=False
    
    # Process high usage metrics
    ${high_usage_report}=    RW.CLI.Run Cli
    ...    cmd=cat asp_high_usage_metrics.json
    TRY
        ${high_usage_json}=    Evaluate    json.loads(r'''${high_usage_report.stdout}''')    json
    EXCEPT
        Log    Failed to load high usage JSON payload, defaulting to empty list.    WARN
        ${high_usage_json}=    Create List
    END
    IF    len(@{high_usage_json}) > 0
        ${high_usage_table}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["Plan_Name", "Resource_Group", "CPU_Usage%", "Memory_Usage%", "Disk_Queue", "Resource_Link"], (.[] | [ .name, .resourceGroup, .metrics.cpu.usage, .metrics.memory.usage, .metrics.disk.queueLength, .resourceLink ]) | @tsv' asp_high_usage_metrics.json | column -t
        RW.Core.Add Pre To Report    High Usage App Service Plans Summary:\n========================\n${high_usage_table.stdout}

        FOR    ${plan}    IN    @{high_usage_json}
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=App Service Plan should not have high resource usage
            ...    actual=High resource usage detected in App Service Plan `${plan['name']}` in resource group `${plan['resourceGroup']}`
            ...    title=High Resource Usage in App Service Plan `${plan['name']}` in resource group `${plan['resourceGroup']}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    details={"plan": ${plan}, "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
            ...    next_steps=Scale up the App Service Plan `${plan['name']}` in resource group `${plan['resourceGroup']}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`.\nOptimize the application code in App service plan `${plan['name']}` in resource group `${plan['resourceGroup']}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${script_output.cmd}
            ...    observed_at=${plan['timestamp']}
        END
    ELSE
        RW.Core.Add Pre To Report    No high usage detected in any App Service Plans in resource group `${AZURE_RESOURCE_GROUP}`
    END
    
    # Process recommendations
    ${recommendations_report}=    RW.CLI.Run Cli
    ...    cmd=cat asp_recommendations.json
    TRY
        ${recommendations_json}=    Evaluate    json.loads(r'''${recommendations_report.stdout}''')    json
    EXCEPT
        Log    Failed to load recommendations JSON payload, defaulting to empty list.    WARN
        ${recommendations_json}=    Create List
    END
    IF    len(@{recommendations_json}) > 0
        # ${rec_table}=    RW.CLI.Run Cli
        # ...    cmd=jq -r '["Plan_Name", "Current_Tier", "Current_Capacity", "CPU_Usage", "Memory_Usage", "Tier_Recommendations", "Capacity_Recommendations", "Resource_Link"], (.[] | [ .name, .currentTier, .currentCapacity, .metrics.cpu, .metrics.memory, (.recommendations.tier | join("; ")), (.recommendations.capacity | join("; ")), .resourceLink ]) | @tsv' asp_recommendations.json | column -t
        # RW.Core.Add Pre To Report    App Service Plan Recommendations Summary:\n========================\n${rec_table.stdout}

        @{EMPTY}=    Create List
        ${EMPTY_DICT}=    Create Dictionary
        FOR    ${plan}    IN    @{recommendations_json}
            ${recs}=    Get From Dictionary    ${plan}    recommendations    ${EMPTY_DICT}
            ${tier_list}=    Get From Dictionary    ${recs}    tier    @{EMPTY}
            ${capacity_list}=    Get From Dictionary    ${recs}    capacity    @{EMPTY}
            ${tier_recs}=    Evaluate    '\\n'.join($tier_list)    json
            ${capacity_recs}=    Evaluate    '\\n'.join($capacity_list)    json
            ${joined_recommendations}=    Set Variable    ${tier_recs}\n${capacity_recs}
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=App Service Plan should be optimally configured for current usage
            ...    actual=Scaling recommendations available for App Service Plan `${plan['name']}` in resource group `${plan['resourceGroup']}`
            ...    title=Scaling Recommendations for App Service Plan `${plan['name']}` in resource group `${plan['resourceGroup']}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    details={"plan": ${plan}, "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
            ...    next_steps=${joined_recommendations}
            ...    reproduce_hint=${script_output.cmd}
            ...    observed_at=${plan['timestamp']}
        END
    ELSE
        RW.Core.Add Pre To Report    No scaling recommendations found for App Service Plans in resource group `${AZURE_RESOURCE_GROUP}`
    END

Analyze App Service Plan Cost Optimization Opportunities in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Analyzes 30-day utilization trends using Azure Monitor to identify underutilized App Service Plans with cost savings opportunities. Provides Azure pricing-based estimates for potential monthly and annual savings with severity bands: Sev4 <$2k/month, Sev3 $2k-$10k/month, Sev2 >$10k/month.
    [Tags]    AppServicePlan    cost-optimization    underutilization    azure-monitor    pricing    access:read-only
    ${cost_optimization}=    RW.CLI.Run Bash File
    ...    bash_file=asp_cost_optimization.sh
    ...    env=${env}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${cost_optimization.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat asp_cost_optimization_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0 
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=App Service Plans should be efficiently utilized to minimize costs
            ...    actual=App Service Plans show underutilization patterns with cost savings opportunities
            ...    title=${issue["title"]}
            ...    reproduce_hint=${cost_optimization.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_step"]}
        END
    END

Analyze App Service Plan Weekly Utilization Trends in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Analyzes week-over-week utilization trends for App Service Plans including CPU, memory, request counts, HTTP error rates, and response times. Detects growth patterns that may indicate scaling needs or performance issues.
    [Tags]    AppServicePlan    Azure    Trends    Utilization    Performance    access:read-only
    ${trend_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=asp_weekly_trend_analysis.sh
    ...    env=${env}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${trend_analysis.stdout}

    ${trend_issues}=    RW.CLI.Run Cli
    ...    cmd=cat asp_weekly_trend_issues.json 2>/dev/null || echo "[]"
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ${trend_issue_list}=    Evaluate    json.loads(r'''${trend_issues.stdout}''')    json
    IF    len(@{trend_issue_list}) > 0 
        FOR    ${issue}    IN    @{trend_issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=App Service Plan utilization trends should be stable or predictably growing
            ...    actual=Significant utilization trend change detected that may require attention
            ...    title=${issue["title"]}
            ...    reproduce_hint=${trend_analysis.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_step"]}
        END
    END


Check App Service Plan Changes in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Lists App Service Plan changes and operations from Azure Activity Log
    [Tags]    AppServicePlan    Azure    Audit    Security    access:read-only

    ${success_file}=    Set Variable    asp_changes_success.json
    ${failed_file}=     Set Variable    asp_changes_failed.json

    ${audit_cmd}=    RW.CLI.Run Bash File
    ...    bash_file=asp-audit.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true

    # Process successful operations
    ${success_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${success_file}
    TRY
        ${success_changes}=    Evaluate    json.loads(r'''${success_data.stdout}''')    json
    EXCEPT
        Log    Failed to load successful changes JSON, defaulting to empty dict.    WARN
        ${success_changes}=    Create Dictionary
    END

    # Process failed operations
    ${failed_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${failed_file}
    TRY
        ${failed_changes}=    Evaluate    json.loads(r'''${failed_data.stdout}''')    json
    EXCEPT
        Log    Failed to load failed changes JSON, defaulting to empty dict.    WARN
        ${failed_changes}=    Create Dictionary
    END

    # Process successful changes
    ${success_length}=    Get Length    ${success_changes}
    IF    ${success_length} > 0
        FOR    ${asp_name}    IN    @{success_changes.keys()}
            ${asp_changes}=    Set Variable    ${success_changes["${asp_name}"]}
            ${asp_changes_length}=    Get Length    ${asp_changes}
            IF    ${asp_changes_length} == 0
                CONTINUE
            END
            ${asp_changes_json}=    Evaluate    json.dumps(${asp_changes})    json
            ${formatted_results}=    RW.CLI.Run Cli
            ...    cmd=printf '%s' '${asp_changes_json}' | jq -r '["Operation", "Timestamp", "Caller", "Security_Level", "Reason"] as $headers | [$headers] + [.[] | [.operation, .timestamp, .caller, .security_classification, .reason]] | .[] | @tsv' | column -t -s $'\\t'
            RW.Core.Add Pre To Report    Successful Changes for App Service Plan (${asp_name}):\n-------------------------------------------------------\n${formatted_results.stdout}\n
            FOR    ${change}    IN    @{asp_changes}
                ${pretty_change}=    Evaluate    pprint.pformat(${change})    modules=pprint
                ${operation}=    Set Variable    ${change['operation']}
                ${caller}=    Set Variable    ${change['caller']}
                ${timestamp}=    Set Variable    ${change['timestamp']}
                ${security_level}=    Set Variable    ${change['security_classification']}
                ${reason}=    Set Variable    ${change['reason']}
                ${resource_url}=    Set Variable    ${change['resourceUrl']}
                ${severity}=    Set Variable If
                ...    '${security_level}' == 'Critical'    3
                ...    '${security_level}' == 'High'        3
                ...    '${security_level}' == 'Medium'      4
                ...    4
                ${enhanced_details}=    Set Variable    ${pretty_change}\\n\\nAzure Portal Link: ${resource_url}
                RW.Core.Add Issue
                ...    severity=${severity}
                ...    expected=App Service Plan operations should be reviewed for security implications in resource group `${AZURE_RESOURCE_GROUP}`
                ...    actual=${security_level.lower()} security operation detected: `${operation}` by `${caller}` at `${timestamp}` on App Service Plan `${asp_name}`
                ...    title=App Service Plan Change `${security_level}` Security: `${operation}` on `${asp_name}` in Resource Group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    details={"changes": ${change}, "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
                ...    reproduce_hint=${audit_cmd.cmd}
                ...    next_steps=Check App Service Plan `${asp_name}` logs for security implications in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    observed_at=${timestamp}
            END
        END
    ELSE
        RW.Core.Add Pre To Report    No successful App Service Plan changes found in resource group `${AZURE_RESOURCE_GROUP}` within the specified timeframe
    END

    # Process failed changes
    ${failed_length}=    Get Length    ${failed_changes}
    IF    ${failed_length} > 0
        FOR    ${asp_name}    IN    @{failed_changes.keys()}
            ${asp_changes}=    Set Variable    ${failed_changes["${asp_name}"]}
            ${asp_changes_length}=    Get Length    ${asp_changes}
            IF    ${asp_changes_length} == 0
                CONTINUE
            END
            ${asp_changes_json}=    Evaluate    json.dumps(${asp_changes})    json
            ${formatted_results}=    RW.CLI.Run Cli
            ...    cmd=printf '%s' '${asp_changes_json}' | jq -r '["Operation", "Timestamp", "Caller", "Security_Level", "Reason"] as $headers | [$headers] + [.[] | [.operation, .timestamp, .caller, .security_classification, .reason]] | .[] | @tsv' | column -t -s $'\\t'
            RW.Core.Add Pre To Report    Failed Changes for App Service Plan (${asp_name}):\\n-----------------------------------------------------\\n${formatted_results.stdout}\\n
            FOR    ${change}    IN    @{asp_changes}
                ${pretty_change}=    Evaluate    pprint.pformat(${change})    modules=pprint
                ${operation}=    Set Variable    ${change['operation']}
                ${caller}=    Set Variable    ${change['caller']}
                ${timestamp}=    Set Variable    ${change['timestamp']}
                ${security_level}=    Set Variable    ${change['security_classification']}
                ${reason}=    Set Variable    ${change['reason']}
                ${resource_url}=    Set Variable    ${change['resourceUrl']}
                ${enhanced_details}=    Set Variable    ${pretty_change}\\n\\nAzure Portal Link: ${resource_url}
                RW.Core.Add Issue
                ...    severity=4
                ...    expected=App Service Plan operations should complete successfully in resource group `${AZURE_RESOURCE_GROUP}`
                ...    actual=Failed operation detected: `${operation}` by `${caller}` at `${timestamp}` on App Service Plan `${asp_name}`
                ...    title=App Service Plan Failed Operation `${operation}` on `${asp_name}` in Resource Group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    details={"details": ${enhanced_details}, "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
                ...    reproduce_hint=${audit_cmd.cmd}
                ...    next_steps=Check errors logs in App Service Plan `${asp_name}` in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`.
                ...    observed_at=${timestamp}
            END
        END
    ELSE
        RW.Core.Add Pre To Report    No failed App Service Plan changes found in resource group `${AZURE_RESOURCE_GROUP}` within the specified timeframe
    END




*** Keywords ***
Suite Initialization
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    ${AZURE_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZURE_RESOURCE_GROUP
    ...    type=string
    ...    description=Azure resource group.
    ...    pattern=\w*
    ${AZURE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure Subscription ID for the resource.  
    ...    pattern=\w*
    ...    default=""
    ${AZURE_SUBSCRIPTION_NAME}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_NAME
    ...    type=string
    ...    description=Azure subscription name.
    ...    pattern=\w*
    ...    default=""
    ${AZURE_ACTIVITY_LOG_OFFSET}=    RW.Core.Import User Variable    AZURE_ACTIVITY_LOG_OFFSET
    ...    type=string
    ...    description=Time offset for activity log collection (e.g., 24h, 7d) (default: 24h)
    ...    pattern=\w+
    ...    default=24h
    ${CPU_THRESHOLD}=    RW.Core.Import User Variable    CPU_THRESHOLD
    ...    type=string
    ...    description=CPU usage threshold percentage for high usage alerts (default: 80)
    ...    pattern=\d+
    ...    default=80
    ${MEMORY_THRESHOLD}=    RW.Core.Import User Variable    MEMORY_THRESHOLD
    ...    type=string
    ...    description=Memory usage threshold percentage for high usage alerts (default: 80)
    ...    pattern=\d+
    ...    default=80
    ${DISK_QUEUE_THRESHOLD}=    RW.Core.Import User Variable    DISK_QUEUE_THRESHOLD
    ...    type=string
    ...    description=Disk queue length threshold for high usage alerts (default: 10)
    ...    pattern=\d+
    ...    default=10
    ${SCALE_UP_CPU_THRESHOLD}=    RW.Core.Import User Variable    SCALE_UP_CPU_THRESHOLD
    ...    type=string
    ...    description=CPU usage threshold percentage for scale up recommendations (default: 70)
    ...    pattern=\d+
    ...    default=70
    ${SCALE_UP_MEMORY_THRESHOLD}=    RW.Core.Import User Variable    SCALE_UP_MEMORY_THRESHOLD
    ...    type=string
    ...    description=Memory usage threshold percentage for scale up recommendations (default: 70)
    ...    pattern=\d+
    ...    default=70
    ${SCALE_DOWN_CPU_THRESHOLD}=    RW.Core.Import User Variable    SCALE_DOWN_CPU_THRESHOLD
    ...    type=string
    ...    description=CPU usage threshold percentage for scale down recommendations (default: 30)
    ...    pattern=\d+
    ...    default=30
    ${SCALE_DOWN_MEMORY_THRESHOLD}=    RW.Core.Import User Variable    SCALE_DOWN_MEMORY_THRESHOLD
    ...    type=string
    ...    description=Memory usage threshold percentage for scale down recommendations (default: 30)
    ...    pattern=\d+
    ...    default=30
    ${METRICS_OFFSET}=    RW.Core.Import User Variable    METRICS_OFFSET
    ...    type=string
    ...    description=Time offset for metrics collection (e.g., 24h, 7d) (default: 24h)
    ...    pattern=\w+
    ...    default=24h
    ${METRICS_INTERVAL}=    RW.Core.Import User Variable    METRICS_INTERVAL
    ...    type=string
    ...    description=Metrics collection interval (e.g., PT1H, PT5M) (default: PT1H)
    ...    pattern=\w+
    ...    default=PT1H
    ${LOOKBACK_WEEKS}=    RW.Core.Import User Variable    LOOKBACK_WEEKS
    ...    type=string
    ...    description=Number of weeks to analyze for trend analysis (default: 4)
    ...    pattern=\d+
    ...    default=4
    ${TIMEOUT_SECONDS}=    RW.Core.Import User Variable    TIMEOUT_SECONDS
    ...    type=string
    ...    description=Timeout in seconds for tasks (default: 900).
    ...    pattern=\d+
    ...    default=900
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${AZURE_ACTIVITY_LOG_OFFSET}    ${AZURE_ACTIVITY_LOG_OFFSET}
    Set Suite Variable    ${CPU_THRESHOLD}    ${CPU_THRESHOLD}
    Set Suite Variable    ${MEMORY_THRESHOLD}    ${MEMORY_THRESHOLD}
    Set Suite Variable    ${DISK_QUEUE_THRESHOLD}    ${DISK_QUEUE_THRESHOLD}
    Set Suite Variable    ${SCALE_UP_CPU_THRESHOLD}    ${SCALE_UP_CPU_THRESHOLD}
    Set Suite Variable    ${SCALE_UP_MEMORY_THRESHOLD}    ${SCALE_UP_MEMORY_THRESHOLD}
    Set Suite Variable    ${SCALE_DOWN_CPU_THRESHOLD}    ${SCALE_DOWN_CPU_THRESHOLD}
    Set Suite Variable    ${SCALE_DOWN_MEMORY_THRESHOLD}    ${SCALE_DOWN_MEMORY_THRESHOLD}
    Set Suite Variable    ${METRICS_OFFSET}    ${METRICS_OFFSET}
    Set Suite Variable    ${METRICS_INTERVAL}    ${METRICS_INTERVAL}
    Set Suite Variable    ${LOOKBACK_WEEKS}    ${LOOKBACK_WEEKS}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_NAME}    ${AZURE_SUBSCRIPTION_NAME}
    Set Suite Variable    ${TIMEOUT_SECONDS}    ${TIMEOUT_SECONDS}
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}", "CPU_THRESHOLD":"${CPU_THRESHOLD}", "MEMORY_THRESHOLD":"${MEMORY_THRESHOLD}", "DISK_QUEUE_THRESHOLD":"${DISK_QUEUE_THRESHOLD}", "SCALE_UP_CPU_THRESHOLD":"${SCALE_UP_CPU_THRESHOLD}", "SCALE_UP_MEMORY_THRESHOLD":"${SCALE_UP_MEMORY_THRESHOLD}", "SCALE_DOWN_CPU_THRESHOLD":"${SCALE_DOWN_CPU_THRESHOLD}", "SCALE_DOWN_MEMORY_THRESHOLD":"${SCALE_DOWN_MEMORY_THRESHOLD}", "METRICS_OFFSET":"${METRICS_OFFSET}", "METRICS_INTERVAL":"${METRICS_INTERVAL}", "LOOKBACK_WEEKS":"${LOOKBACK_WEEKS}", "AZURE_ACTIVITY_LOG_OFFSET": "${AZURE_ACTIVITY_LOG_OFFSET}"}
    # Set Azure subscription context for Cloud Custodian
    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZURE_SUBSCRIPTION_ID}
    ...    include_in_history=false