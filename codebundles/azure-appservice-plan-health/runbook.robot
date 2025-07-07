*** Settings ***
Documentation       Check Azure App Service Plan health by identifying high usage issues and providing scaling recommendations
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
Suite Setup         Suite Initialization


*** Tasks ***
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
            ...    actual=High resource usage detected in App Service Plan ${plan['name']} in resource group ${plan['resourceGroup']}
            ...    title=High Resource Usage in App Service Plan ${plan['name']} in resource group ${plan['resourceGroup']}
            ...    details=${plan}
            ...    next_steps=Consider scaling up the App Service Plan or optimizing the application code.
            ...    reproduce_hint=${script_output.cmd}
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
            ...    actual=Scaling recommendations available for App Service Plan ${plan['name']} in resource group ${plan['resourceGroup']}
            ...    title=Scaling Recommendations for App Service Plan ${plan['name']} in resource group ${plan['resourceGroup']}
            ...    details=${plan}
            ...    next_steps=${joined_recommendations}
            ...    reproduce_hint=${script_output.cmd}
        END
    ELSE
        RW.Core.Add Pre To Report    No scaling recommendations found for App Service Plans in resource group `${AZURE_RESOURCE_GROUP}`
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
    ${UNUSED_STORAGE_ACCOUNT_TIMEFRAME}=    RW.Core.Import User Variable    UNUSED_STORAGE_ACCOUNT_TIMEFRAME
    ...    type=string
    ...    description=The timeframe in hours to check for unused storage accounts (e.g., 720 for 30 days)
    ...    pattern=\d+
    ...    default=24
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
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${UNUSED_STORAGE_ACCOUNT_TIMEFRAME}    ${UNUSED_STORAGE_ACCOUNT_TIMEFRAME}
    Set Suite Variable    ${CPU_THRESHOLD}    ${CPU_THRESHOLD}
    Set Suite Variable    ${MEMORY_THRESHOLD}    ${MEMORY_THRESHOLD}
    Set Suite Variable    ${DISK_QUEUE_THRESHOLD}    ${DISK_QUEUE_THRESHOLD}
    Set Suite Variable    ${SCALE_UP_CPU_THRESHOLD}    ${SCALE_UP_CPU_THRESHOLD}
    Set Suite Variable    ${SCALE_UP_MEMORY_THRESHOLD}    ${SCALE_UP_MEMORY_THRESHOLD}
    Set Suite Variable    ${SCALE_DOWN_CPU_THRESHOLD}    ${SCALE_DOWN_CPU_THRESHOLD}
    Set Suite Variable    ${SCALE_DOWN_MEMORY_THRESHOLD}    ${SCALE_DOWN_MEMORY_THRESHOLD}
    Set Suite Variable    ${METRICS_OFFSET}    ${METRICS_OFFSET}
    Set Suite Variable    ${METRICS_INTERVAL}    ${METRICS_INTERVAL}
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}", "CPU_THRESHOLD":"${CPU_THRESHOLD}", "MEMORY_THRESHOLD":"${MEMORY_THRESHOLD}", "DISK_QUEUE_THRESHOLD":"${DISK_QUEUE_THRESHOLD}", "SCALE_UP_CPU_THRESHOLD":"${SCALE_UP_CPU_THRESHOLD}", "SCALE_UP_MEMORY_THRESHOLD":"${SCALE_UP_MEMORY_THRESHOLD}", "SCALE_DOWN_CPU_THRESHOLD":"${SCALE_DOWN_CPU_THRESHOLD}", "SCALE_DOWN_MEMORY_THRESHOLD":"${SCALE_DOWN_MEMORY_THRESHOLD}", "METRICS_OFFSET":"${METRICS_OFFSET}", "METRICS_INTERVAL":"${METRICS_INTERVAL}"}
