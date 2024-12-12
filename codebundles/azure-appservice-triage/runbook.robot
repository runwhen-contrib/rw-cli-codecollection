*** Settings ***
Documentation       Triages an Azure App Service and its workloads, checking its status and logs and verifying key metrics.
Metadata            Author    jon-funk
Metadata            Display Name    Azure App Service Triage
Metadata            Supports    Azure    App Service    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
# Check App Service `${APP_SERVICE_NAME}` Health Status In Resource Group `${AZ_RESOURCE_GROUP}`
#     [Documentation]    Checks the health status of a appservice workload.
#     [Tags]    
#     ${process}=    RW.CLI.Run Bash File
#     ...    bash_file=appservice_health.sh
#     ...    env=${env}
#     ...    timeout_seconds=180
#     ...    include_in_history=false
#     IF    ${process.returncode} > 0
#         RW.Core.Add Issue    title=App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}` Failing Health Check
#         ...    severity=2
#         ...    next_steps=Tail the logs of the App Service `${APP_SERVICE_NAME}` in resource group `${AZ_RESOURCE_GROUP}`\nReview resource usage metrics of App Service `${APP_SERVICE_NAME}` in resource group `${AZ_RESOURCE_GROUP}`
#         ...    expected=App Service `${APP_SERVICE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` should not be failing its health check
#         ...    actual=App Service `${APP_SERVICE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` is failing its health check
#         ...    reproduce_hint=Run appservice_health.sh
#         ...    details=${process.stdout}
#     END
#     RW.Core.Add Pre To Report    ${process.stdout}

# Check App Service `${APP_SERVICE_NAME}` Key Metrics In Resource Group `${AZ_RESOURCE_GROUP}`
#     [Documentation]    Reviews key metrics for the app service and generates a report
#     [Tags]    
#     ${process}=    RW.CLI.Run Bash File
#     ...    bash_file=appservice_metrics.sh
#     ...    env=${env}
#     ...    timeout_seconds=180
#     ...    include_in_history=false
#     ${next_steps}=    RW.CLI.Run Cli    cmd=echo -e "${process.stdout}" | grep "Next Steps" -A 20 | tail -n +2
#     IF    ${process.returncode} > 0
#         RW.Core.Add Issue    title=App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}` Failed Metric Check
#         ...    severity=2
#         ...    next_steps=${next_steps.stdout}
#         ...    expected=App Service `${APP_SERVICE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has no unusual metrics
#         ...    actual=App Service `${APP_SERVICE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` metric check did not pass
#         ...    reproduce_hint=Run appservice_metrics.sh
#         ...    details=${process.stdout}
#     END
#     RW.Core.Add Pre To Report    ${process.stdout}

# Get App Service `${APP_SERVICE_NAME}` Logs In Resource Group `${AZ_RESOURCE_GROUP}`
#     [Documentation]    Fetch logs of appservice workload
#     [Tags]    appservice    logs    tail
#     ${process}=    RW.CLI.Run Bash File
#     ...    bash_file=appservice_logs.sh
#     ...    env=${env}
#     ...    timeout_seconds=180
#     ...    include_in_history=false
#     RW.Core.Add Pre To Report    ${process.stdout}

Check Configuration Health of App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch logs of appservice workload
    [Tags]    appservice    logs    tail
    ${config_health}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_config_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${config_health.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/az_app_service_health.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=App Service `${APP_SERVICE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has a healthy configuration
            ...    actual=App Service `${APP_SERVICE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has configuration reccomentations
            ...    reproduce_hint=${config_health.cmd}
            ...    details=${item["details"]}        
        END
    END


# Scan App Service `${APP_SERVICE_NAME}` Activities In Resource Group `${AZ_RESOURCE_GROUP}`
#     [Documentation]    Gets the events of appservice and checks for errors
#     [Tags]    appservice    monitor    events    errors
#     ${process}=    RW.CLI.Run Bash File
#     ...    bash_file=appservice_activities.sh
#     ...    env=${env}
#     ...    timeout_seconds=180
#     ...    include_in_history=false
#     ${next_steps}=    RW.CLI.Run Cli    cmd=echo -e "${process.stdout}" | grep "Next Steps" -A 20 | tail -n +2
#     IF    ${process.returncode} > 0
#         RW.Core.Add Issue    title=Azure Resource `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}` Has Errors In Activities
#         ...    severity=3
#         ...    next_steps=${next_steps.stdout}
#         ...    expected=Azure Resource `${APP_SERVICE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has no errors or criticals in activity logs
#         ...    actual=Azure Resource `${APP_SERVICE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has errors or critical events in activity logs
#         ...    reproduce_hint=Run activities.sh
#         ...    details=${process.stdout}
#     END
#     RW.Core.Add Pre To Report    ${process.stdout}

*** Keywords ***
Suite Initialization

    ${AZ_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZ_RESOURCE_GROUP
    ...    type=string
    ...    description=The resource group to perform actions against.
    ...    pattern=\w*
    ${APP_SERVICE_NAME}=    RW.Core.Import User Variable    APP_SERVICE_NAME
    ...    type=string
    ...    description=The Azure AppService to triage.
    ...    pattern=\w*
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    ${TIME_PERIOD_MINUTES}=    RW.Core.Import User Variable    TIME_PERIOD_MINUTES
    ...    type=string
    ...    description=The time period, in minutes, to look back for activites/events. 
    ...    pattern=\w*
    ...    default=10
    Set Suite Variable    ${APP_SERVICE_NAME}    ${APP_SERVICE_NAME}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable    ${TIME_PERIOD_MINUTES}    ${TIME_PERIOD_MINUTES}
    Set Suite Variable
    ...    ${env}
    ...    {"APP_SERVICE_NAME":"${APP_SERVICE_NAME}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}", "OUTPUT_DIR":"${OUTPUT DIR}", "TIME_PERIOD_MINUTES": "${TIME_PERIOD_MINUTES}"}
