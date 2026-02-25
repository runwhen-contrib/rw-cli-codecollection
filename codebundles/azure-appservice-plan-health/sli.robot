*** Settings ***
Documentation       Check Azure App Service Plan health by identifying availability issues, high capacity usage
Metadata            Author    saurabh3460
Metadata            Display Name    Azure    App Service Plan
Metadata            Supports    Azure    App Service Plan    Health
Force Tags          Azure    App Service Plan    Health

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization
*** Tasks ***
Count App Service Plans with Health Status of `Available` in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Count Azure App Service Plans with health status of `Available`
    [Tags]    AppServicePlan    Azure    Health    access:read-only    data:config
    ${output}=    RW.CLI.Run Bash File
    ...    bash_file=asp-health-check.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat asp_health.json
    TRY
        ${health_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${health_list}=    Create List
    END
    ${count}=    Evaluate    len([health for health in ${health_list} if health['properties']['availabilityState'] == 'Available'])
    ${available_asp_score}=    Evaluate    1 if int(${count}) >= 1 else 0
    Set Global Variable    ${available_asp_score}
    RW.Core.Push Metric    ${available_asp_score}    sub_name=availability


Count App Service Plans with High Capacity Usage in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Count App Service Plans with high CPU, memory, or disk queue usage
    [Tags]    AppService    Azure    Health    access:read-only    data:config
    ${output}=    RW.CLI.Run Bash File
    ...    bash_file=check_appservice_plan_capacity.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=False
    ${high_usage_report}=    RW.CLI.Run Cli
    ...    cmd=cat asp_high_usage_metrics.json
    TRY
        ${high_usage_json}=    Evaluate    json.loads(r'''${high_usage_report.stdout}''')    json
    EXCEPT
        Log    Failed to load high usage JSON payload, defaulting to empty list.    WARN
        ${high_usage_json}=    Create List
    END
    ${count}=    Evaluate    len(${high_usage_json})
    ${appservice_high_usage_score}=    Evaluate    1 if int(${count}) <= int(${MAX_HIGH_USAGE_APP_SERVICE_PLAN}) else 0
    Set Global Variable    ${appservice_high_usage_score}
    RW.Core.Push Metric    ${appservice_high_usage_score}    sub_name=capacity_usage

Generate Health Score
    ${health_score}=    Evaluate  (${appservice_high_usage_score} + ${available_asp_score}) / 2
    ${health_score}=    Convert to Number    ${health_score}  2
    RW.Core.Push Metric    ${health_score}


*** Keywords ***
Suite Initialization
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    ${AZURE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure Subscription ID for the resource.  
    ...    pattern=\w*
    ...    default=""
    ${AZURE_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZURE_RESOURCE_GROUP
    ...    type=string
    ...    description=Azure resource group.
    ...    pattern=\w*
    ${MAX_UNUSED_DISK}=    RW.Core.Import User Variable    MAX_UNUSED_DISK
    ...    type=string
    ...    description=The maximum number of unused disks allowed in the subscription.
    ...    pattern=^\d+$
    ...    example=1
    ...    default=0
    ${MAX_UNUSED_SNAPSHOT}=    RW.Core.Import User Variable    MAX_UNUSED_SNAPSHOT
    ...    type=string
    ...    description=The maximum number of unused snapshots allowed in the subscription.
    ...    pattern=^\d+$
    ...    example=1
    ...    default=0
    ${UNUSED_STORAGE_ACCOUNT_TIMEFRAME}=    RW.Core.Import User Variable    UNUSED_STORAGE_ACCOUNT_TIMEFRAME
    ...    type=string
    ...    description=The timeframe in hours to check for unused storage accounts (e.g., 720 for 30 days)
    ...    pattern=\d+
    ...    default=24
    ${MAX_UNUSED_STORAGE_ACCOUNT}=    RW.Core.Import User Variable    MAX_UNUSED_STORAGE_ACCOUNT
    ...    type=string
    ...    description=The maximum number of unused storage accounts allowed in the subscription.
    ...    pattern=^\d+$
    ...    example=1
    ...    default=0
    ${MAX_PUBLIC_ACCESS_STORAGE_ACCOUNT}=    RW.Core.Import User Variable    MAX_PUBLIC_ACCESS_STORAGE_ACCOUNT
    ...    type=string
    ...    description=The maximum number of storage accounts with public access allowed in the subscription.
    ...    pattern=^\d+$
    ...    example=1
    ...    default=0
    ${MAX_HIGH_USAGE_APP_SERVICE_PLAN}=    RW.Core.Import User Variable    MAX_HIGH_USAGE_APP_SERVICE_PLAN
    ...    type=string
    ...    description=The maximum number of high usage App Service Plans allowed in the subscription.
    ...    pattern=^\d+$
    ...    example=1
    ...    default=0
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${MAX_UNUSED_DISK}    ${MAX_UNUSED_DISK}
    Set Suite Variable    ${MAX_UNUSED_SNAPSHOT}    ${MAX_UNUSED_SNAPSHOT}
    set Suite Variable    ${UNUSED_STORAGE_ACCOUNT_TIMEFRAME}    ${UNUSED_STORAGE_ACCOUNT_TIMEFRAME}
    Set Suite Variable    ${MAX_UNUSED_STORAGE_ACCOUNT}    ${MAX_UNUSED_STORAGE_ACCOUNT}
    Set Suite Variable    ${MAX_PUBLIC_ACCESS_STORAGE_ACCOUNT}    ${MAX_PUBLIC_ACCESS_STORAGE_ACCOUNT}
    Set Suite Variable    ${MAX_HIGH_USAGE_APP_SERVICE_PLAN}    ${MAX_HIGH_USAGE_APP_SERVICE_PLAN}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}"}
    # Set Azure subscription context for Cloud Custodian
    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZURE_SUBSCRIPTION_ID}
    ...    include_in_history=false