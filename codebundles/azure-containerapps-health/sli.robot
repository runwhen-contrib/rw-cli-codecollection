*** Settings ***
Documentation       Provides Service Level Indicators (SLIs) for Azure Container Apps health and performance monitoring.
Metadata            Author    stewartshea
Metadata            Display Name    Azure Container Apps SLI
Metadata            Supports    Azure    ContainerApps    SLI    Monitoring

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Get Container App Availability SLI
    [Documentation]    Calculates availability SLI based on replica health and provisioning status
    [Tags]    containerapp    availability    sli
    ${availability_check}=    RW.CLI.Run Bash File
    ...    bash_file=containerapp_availability_sli.sh
    ...    env=${env}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ${availability_metric}=    RW.CLI.Run Cli
    ...    cmd=cat container_app_availability_sli.txt
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    RW.Core.Add Pre To Report    Container App Availability SLI:\n${availability_metric.stdout}

Get Container App Performance SLI  
    [Documentation]    Calculates performance SLI based on response times and error rates
    [Tags]    containerapp    performance    sli
    ${performance_check}=    RW.CLI.Run Bash File
    ...    bash_file=containerapp_performance_sli.sh
    ...    env=${env}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ${performance_metric}=    RW.CLI.Run Cli
    ...    cmd=cat container_app_performance_sli.txt
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    RW.Core.Add Pre To Report    Container App Performance SLI:\n${performance_metric.stdout}

Get Container App Resource Utilization SLI
    [Documentation]    Calculates resource utilization SLI based on CPU and memory usage
    [Tags]    containerapp    resources    sli
    ${resource_check}=    RW.CLI.Run Bash File
    ...    bash_file=containerapp_resource_sli.sh
    ...    env=${env}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ${resource_metric}=    RW.CLI.Run Cli
    ...    cmd=cat container_app_resource_sli.txt
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    RW.Core.Add Pre To Report    Container App Resource Utilization SLI:\n${resource_metric.stdout}

*** Keywords ***
Suite Initialization
    ${AZ_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZ_RESOURCE_GROUP
    ...    type=string
    ...    description=The resource group containing the Container App.
    ...    pattern=\w*
    ${CONTAINER_APP_NAME}=    RW.Core.Import User Variable    CONTAINER_APP_NAME
    ...    type=string
    ...    description=The Azure Container App to monitor.
    ...    pattern=\w*
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    ${AZURE_RESOURCE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_RESOURCE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure Subscription ID for the resource.
    ...    pattern=\w*
    ...    default=""
    ${SLI_TIME_PERIOD_MINUTES}=    RW.Core.Import User Variable    SLI_TIME_PERIOD_MINUTES
    ...    type=string
    ...    description=The time period, in minutes, for SLI calculations.
    ...    pattern=\w*
    ...    default=60
    ${AVAILABILITY_TARGET}=    RW.Core.Import User Variable    AVAILABILITY_TARGET
    ...    type=string
    ...    description=Target availability percentage for SLI (e.g., 99.9).
    ...    pattern=\w*
    ...    default=99.5
    ${PERFORMANCE_TARGET_MS}=    RW.Core.Import User Variable    PERFORMANCE_TARGET_MS
    ...    type=string
    ...    description=Target response time in milliseconds for performance SLI.
    ...    pattern=\w*
    ...    default=1000
    ${ERROR_RATE_TARGET}=    RW.Core.Import User Variable    ERROR_RATE_TARGET
    ...    type=string
    ...    description=Maximum acceptable error rate percentage.
    ...    pattern=\w*
    ...    default=1.0

    Set Suite Variable    ${CONTAINER_APP_NAME}    ${CONTAINER_APP_NAME}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable    ${AZURE_RESOURCE_SUBSCRIPTION_ID}    ${AZURE_RESOURCE_SUBSCRIPTION_ID}
    Set Suite Variable    ${SLI_TIME_PERIOD_MINUTES}    ${SLI_TIME_PERIOD_MINUTES}
    Set Suite Variable    ${AVAILABILITY_TARGET}    ${AVAILABILITY_TARGET}
    Set Suite Variable    ${PERFORMANCE_TARGET_MS}    ${PERFORMANCE_TARGET_MS}
    Set Suite Variable    ${ERROR_RATE_TARGET}    ${ERROR_RATE_TARGET}

    Set Suite Variable
    ...    ${env}
    ...    {"CONTAINER_APP_NAME":"${CONTAINER_APP_NAME}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}", "AZURE_RESOURCE_SUBSCRIPTION_ID":"${AZURE_RESOURCE_SUBSCRIPTION_ID}", "SLI_TIME_PERIOD_MINUTES":"${SLI_TIME_PERIOD_MINUTES}", "AVAILABILITY_TARGET":"${AVAILABILITY_TARGET}", "PERFORMANCE_TARGET_MS":"${PERFORMANCE_TARGET_MS}", "ERROR_RATE_TARGET":"${ERROR_RATE_TARGET}"} 