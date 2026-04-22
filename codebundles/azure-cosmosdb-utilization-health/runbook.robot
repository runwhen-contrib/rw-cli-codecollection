*** Settings ***
Documentation       Evaluates Azure Cosmos DB utilization via normalized RU, total RU, throttling, latency, storage growth, and throughput sizing to support capacity planning.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Azure Cosmos DB Utilization and Sizing Health
Metadata            Supports    Azure    CosmosDB    Utilization    Metrics    Health
Force Tags          Azure    CosmosDB    Utilization    Health

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Analyze Cosmos DB Normalized RU Consumption Trends for Account `${COSMOSDB_ACCOUNT_NAME}` in Resource Group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Pulls Azure Monitor time series for normalized RU consumption to detect sustained pressure or rising trends versus the first half of the lookback window.
    [Tags]    Azure    CosmosDB    Metrics    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=cosmosdb-normalized-ru-trends.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./cosmosdb-normalized-ru-trends.sh
    RW.Core.Add Pre To Report    ${result.stdout}
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat cosmosdb_normalized_ru_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Normalized RU consumption should remain below ${NORMALIZED_RU_THRESHOLD_PCT}% for most of the window without a sustained upward trend for account `${COSMOSDB_ACCOUNT_NAME}`.
            ...    actual=Elevated or rising normalized RU consumption was detected for the scoped Cosmos DB account(s).
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Analyze Cosmos DB Total Request Units Consumed for Account `${COSMOSDB_ACCOUNT_NAME}` in Resource Group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Aggregates Total Request Units over the lookback window and flags sharp growth between the first and second half of the window.
    [Tags]    Azure    CosmosDB    Metrics    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=cosmosdb-total-ru-consumed.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=./cosmosdb-total-ru-consumed.sh
    RW.Core.Add Pre To Report    ${result.stdout}
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat cosmosdb_total_ru_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Total RU consumption growth should stay within expected baselines for account `${COSMOSDB_ACCOUNT_NAME}`.
            ...    actual=A sharp increase in daily TotalRequestUnits was detected across the analysis window.
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Check Cosmos DB Throttling and HTTP 429 Rate for Account `${COSMOSDB_ACCOUNT_NAME}` in Resource Group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Correlates TotalRequests with HTTP 429 status against provisioned capacity to flag undersizing or hot-key effects.
    [Tags]    Azure    CosmosDB    Throttling    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=cosmosdb-throttling-429.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=./cosmosdb-throttling-429.sh
    RW.Core.Add Pre To Report    ${result.stdout}
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat cosmosdb_throttle_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=429 responses should stay below ${THROTTLE_EVENTS_THRESHOLD} in the lookback window for account `${COSMOSDB_ACCOUNT_NAME}`.
            ...    actual=Throttling (HTTP 429) was observed in Azure Monitor TotalRequests metrics.
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Analyze Cosmos DB Server-side Latency for Account `${COSMOSDB_ACCOUNT_NAME}` in Resource Group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Reviews ServerSideLatency averages for regressions that often precede saturation or hot partitions.
    [Tags]    Azure    CosmosDB    Latency    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=cosmosdb-server-latency.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=./cosmosdb-server-latency.sh
    RW.Core.Add Pre To Report    ${result.stdout}
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat cosmosdb_latency_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Server-side latency should remain below ${SERVER_LATENCY_MS_THRESHOLD} ms (hourly average) for account `${COSMOSDB_ACCOUNT_NAME}`.
            ...    actual=Elevated ServerSideLatency was observed in the lookback window.
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Analyze Cosmos DB Data and Index Storage Utilization for Account `${COSMOSDB_ACCOUNT_NAME}` in Resource Group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Tracks DataUsage and IndexUsage to flag rapid expansion that can drive partition count and cost.
    [Tags]    Azure    CosmosDB    Storage    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=cosmosdb-storage-utilization.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=./cosmosdb-storage-utilization.sh
    RW.Core.Add Pre To Report    ${result.stdout}
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat cosmosdb_storage_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Data and index storage growth should remain within expected bounds (below ~${STORAGE_GROWTH_PCT_THRESHOLD}% swing) for account `${COSMOSDB_ACCOUNT_NAME}`.
            ...    actual=Rapid storage or index growth was detected across the window.
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Analyze Cosmos DB Provisioned Throughput vs Consumed Load for Account `${COSMOSDB_ACCOUNT_NAME}` in Resource Group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Compares normalized RU with ProvisionedThroughput signals to highlight undersizing risk or sustained over-provisioning.
    [Tags]    Azure    CosmosDB    Throughput    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=cosmosdb-throughput-sizing.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=./cosmosdb-throughput-sizing.sh
    RW.Core.Add Pre To Report    ${result.stdout}
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat cosmosdb_throughput_sizing_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Throughput should be right-sized: normalized RU below ${NORMALIZED_RU_THRESHOLD_PCT}% for healthy headroom, and not chronically under ~${UNDERUTILIZED_NORMALIZED_PCT}% while heavily provisioned.
            ...    actual=A throughput sizing concern (ceiling risk or over-provisioning) was detected from metrics.
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END


*** Keywords ***
Suite Initialization
    TRY
        ${azure_credentials}=    RW.Core.Import Secret
        ...    azure_credentials
        ...    type=string
        ...    description=JSON with CLIENT_ID, TENANT_ID, CLIENT_SECRET, SUBSCRIPTION_ID for Azure CLI.
        ...    pattern=\w*
    EXCEPT
        Log    azure_credentials secret not provided; relying on ambient Azure CLI login.    WARN
        ${azure_credentials}=    Set Variable    ${EMPTY}
    END
    ${AZ_SUBSCRIPTION}=    RW.Core.Import User Variable    AZ_SUBSCRIPTION
    ...    type=string
    ...    description=Azure subscription ID (UUID).
    ...    pattern=.*
    ${AZURE_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZURE_RESOURCE_GROUP
    ...    type=string
    ...    description=Resource group containing Cosmos DB account(s).
    ...    pattern=.*
    ${COSMOSDB_ACCOUNT_NAME}=    RW.Core.Import User Variable    COSMOSDB_ACCOUNT_NAME
    ...    type=string
    ...    description=Cosmos DB account name, or All for every account in the resource group.
    ...    pattern=.*
    ...    default=All
    ${METRICS_LOOKBACK_DAYS}=    RW.Core.Import User Variable    METRICS_LOOKBACK_DAYS
    ...    type=string
    ...    description=Days of historical metrics for analysis.
    ...    pattern=^\d+$
    ...    default=14
    ${NORMALIZED_RU_THRESHOLD_PCT}=    RW.Core.Import User Variable    NORMALIZED_RU_THRESHOLD_PCT
    ...    type=string
    ...    description=Normalized RU percentage above which to raise utilization issues.
    ...    pattern=^\d+$
    ...    default=80
    ${THROTTLE_EVENTS_THRESHOLD}=    RW.Core.Import User Variable    THROTTLE_EVENTS_THRESHOLD
    ...    type=string
    ...    description=Minimum count of HTTP 429 requests in the window to flag throttling.
    ...    pattern=^\d+$
    ...    default=1
    ${SERVER_LATENCY_MS_THRESHOLD}=    RW.Core.Import User Variable    SERVER_LATENCY_MS_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable hourly average ServerSideLatency in milliseconds.
    ...    pattern=^\d+$
    ...    default=100
    ${STORAGE_GROWTH_PCT_THRESHOLD}=    RW.Core.Import User Variable    STORAGE_GROWTH_PCT_THRESHOLD
    ...    type=string
    ...    description=Percent growth from start to end of window that triggers storage/index expansion issues.
    ...    pattern=^\d+$
    ...    default=25
    ${UNDERUTILIZED_NORMALIZED_PCT}=    RW.Core.Import User Variable    UNDERUTILIZED_NORMALIZED_PCT
    ...    type=string
    ...    description=Normalized RU level used with provisioned throughput to suggest over-provisioning.
    ...    pattern=^\d+$
    ...    default=15
    ${RU_DAILY_GROWTH_RATIO}=    RW.Core.Import User Variable    RU_DAILY_GROWTH_RATIO
    ...    type=string
    ...    description=Ratio of later-window to earlier-window daily Total RU that indicates a spike.
    ...    pattern=^[0-9.]+$
    ...    default=1.5
    ${AZURE_SUBSCRIPTION_NAME}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_NAME
    ...    type=string
    ...    description=Friendly subscription name for reporting context.
    ...    pattern=.*
    ...    default=Azure Subscription
    ${env}=    Create Dictionary
    ...    AZ_SUBSCRIPTION=${AZ_SUBSCRIPTION}
    ...    AZURE_SUBSCRIPTION_ID=${AZ_SUBSCRIPTION}
    ...    AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP}
    ...    COSMOSDB_ACCOUNT_NAME=${COSMOSDB_ACCOUNT_NAME}
    ...    METRICS_LOOKBACK_DAYS=${METRICS_LOOKBACK_DAYS}
    ...    NORMALIZED_RU_THRESHOLD_PCT=${NORMALIZED_RU_THRESHOLD_PCT}
    ...    THROTTLE_EVENTS_THRESHOLD=${THROTTLE_EVENTS_THRESHOLD}
    ...    SERVER_LATENCY_MS_THRESHOLD=${SERVER_LATENCY_MS_THRESHOLD}
    ...    STORAGE_GROWTH_PCT_THRESHOLD=${STORAGE_GROWTH_PCT_THRESHOLD}
    ...    UNDERUTILIZED_NORMALIZED_PCT=${UNDERUTILIZED_NORMALIZED_PCT}
    ...    RU_DAILY_GROWTH_RATIO=${RU_DAILY_GROWTH_RATIO}
    Set Suite Variable    ${env}    ${env}
    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZ_SUBSCRIPTION}
    ...    include_in_history=false
