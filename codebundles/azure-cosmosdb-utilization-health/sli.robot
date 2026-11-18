*** Settings ***
Documentation       Measures Cosmos DB utilization health using normalized RU, HTTP 429 rate, and server-side latency. Produces a value between 0 (failing) and 1 (fully passing).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Azure Cosmos DB Utilization SLI
Metadata            Supports    Azure    CosmosDB    Utilization    SLI
Force Tags          Azure    CosmosDB    SLI

Library             BuiltIn
Library             Collections
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Collect Cosmos DB SLI Snapshot for Account `${COSMOSDB_ACCOUNT_NAME}`
    [Documentation]    Runs a short-window Azure Monitor query set for normalized RU, 429 totals, and server latency.
    [Tags]    Azure    CosmosDB    access:read-only    data:metrics
    ${snap}=    RW.CLI.Run Bash File
    ...    bash_file=cosmosdb_sli_snapshot.sh
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    ...    cmd_override=./cosmosdb_sli_snapshot.sh

Publish Cosmos DB Utilization Health Score
    [Documentation]    Averages binary dimension scores into the primary 0-1 health metric.
    [Tags]    Azure    CosmosDB    access:read-only    data:metrics
    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat cosmosdb_sli_output.json
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    TRY
        ${data}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    SLI JSON parse failed; emitting zero health score.    WARN
        RW.Core.Push Metric    0
        RETURN
    END
    ${s1}=    Get From Dictionary    ${data}    normalized_ru_ok
    ${s2}=    Get From Dictionary    ${data}    throttle_ok
    ${s3}=    Get From Dictionary    ${data}    latency_ok
    RW.Core.Push Metric    ${s1}    sub_name=normalized_ru
    RW.Core.Push Metric    ${s2}    sub_name=throttle_429
    RW.Core.Push Metric    ${s3}    sub_name=server_latency
    ${health_score}=    Evaluate    (${s1} + ${s2} + ${s3}) / 3
    ${health_score}=    Convert To Number    ${health_score}    2
    RW.Core.Add to Report    Health Score: ${health_score}
    RW.Core.Push Metric    ${health_score}


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
    ${NORMALIZED_RU_THRESHOLD_PCT}=    RW.Core.Import User Variable    NORMALIZED_RU_THRESHOLD_PCT
    ...    type=string
    ...    description=Normalized RU percentage threshold for SLI.
    ...    pattern=^\d+$
    ...    default=80
    ${THROTTLE_EVENTS_THRESHOLD}=    RW.Core.Import User Variable    THROTTLE_EVENTS_THRESHOLD
    ...    type=string
    ...    description=429 count threshold for SLI failure.
    ...    pattern=^\d+$
    ...    default=1
    ${SERVER_LATENCY_MS_THRESHOLD}=    RW.Core.Import User Variable    SERVER_LATENCY_MS_THRESHOLD
    ...    type=string
    ...    description=ServerSideLatency ms threshold for SLI failure.
    ...    pattern=^\d+$
    ...    default=100
    ${SLI_METRICS_OFFSET}=    RW.Core.Import User Variable    SLI_METRICS_OFFSET
    ...    type=string
    ...    description=Short lookback for SLI queries (e.g. 2d).
    ...    pattern=.*
    ...    default=2d
    ${env}=    Create Dictionary
    ...    AZ_SUBSCRIPTION=${AZ_SUBSCRIPTION}
    ...    AZURE_SUBSCRIPTION_ID=${AZ_SUBSCRIPTION}
    ...    AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP}
    ...    COSMOSDB_ACCOUNT_NAME=${COSMOSDB_ACCOUNT_NAME}
    ...    NORMALIZED_RU_THRESHOLD_PCT=${NORMALIZED_RU_THRESHOLD_PCT}
    ...    THROTTLE_EVENTS_THRESHOLD=${THROTTLE_EVENTS_THRESHOLD}
    ...    SERVER_LATENCY_MS_THRESHOLD=${SERVER_LATENCY_MS_THRESHOLD}
    ...    SLI_METRICS_OFFSET=${SLI_METRICS_OFFSET}
    Set Suite Variable    ${env}    ${env}
    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZ_SUBSCRIPTION}
    ...    include_in_history=false
