*** Settings ***
Documentation       Triages an Azure App Service and its workloads, checking its status and logs and verifying key metrics.
Metadata            Author    stewartshea
Metadata            Display Name    Azure App Service Triage
Metadata            Supports    Azure    App Service    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check App Service `${APP_SERVICE_NAME}` Health Check Metrics In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks the health status of a appservice workload.
    [Tags]    
    ${health_check_metric}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_health_metric.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${health_check_metric.stdout}
    
    ${summary}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/app_service_health_check_summary.txt
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${summary.stdout}

    ${metrics}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/app_service_health_check_metrics.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${metrics.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/app_service_health_check_issues.json
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
            ...    expected=App Service `${APP_SERVICE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has is reported healthy
            ...    actual=App Service `${APP_SERVICE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has health check metric issues
            ...    reproduce_hint=${health_check_metric.cmd}
            ...    details=${item["details"]}        
        END
    END
    RW.Core.Add Pre To Report    ${health_check_metric.stdout}

Fetch App Service `${APP_SERVICE_NAME}` Utilization Metrics In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Reviews key metrics for the app service and generates a report
    [Tags]    
    ${metric_health}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_metric_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${metric_health.stdout}
    ${summary}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/app_service_metrics_summary.txt
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${summary.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/app_service_issues.json
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
            ...    expected=App Service `${APP_SERVICE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has healthy metrics
            ...    actual=App Service `${APP_SERVICE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has metric issues
            ...    reproduce_hint=${metric_health.cmd}
            ...    details=${item["details"]}        
        END
    END


Get App Service `${APP_SERVICE_NAME}` Logs In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch logs of appservice workload
    [Tags]    appservice    logs    tail
    ${logs}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_logs.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${logs.stdout}

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


Fetch App Service `${APP_SERVICE_NAME}` Activities In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Gets the events of appservice and checks for errors
    [Tags]    appservice    monitor    events    errors
    ${activities}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_activities.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${activities.stdout}

    ${issues}=    RW.CLI.Run Cli    cmd=cat ${OUTPUT DIR}/app_service_activities_issues.json
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=App Service `${APP_SERVICE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has no Warning/Error/Critical activities
            ...    actual=App Service `${APP_SERVICE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has Warning/Error/Critical activities
            ...    reproduce_hint=${activities.cmd}
            ...    details=${item["details"]}        
        END
    END

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
    ...    description=The time period, in minutes, to look back for activities/events. 
    ...    pattern=\w*
    ...    default=10
    Set Suite Variable    ${APP_SERVICE_NAME}    ${APP_SERVICE_NAME}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable    ${TIME_PERIOD_MINUTES}    ${TIME_PERIOD_MINUTES}
    Set Suite Variable
    ...    ${env}
    ...    {"APP_SERVICE_NAME":"${APP_SERVICE_NAME}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}", "OUTPUT_DIR":"${OUTPUT DIR}", "TIME_PERIOD_MINUTES": "${TIME_PERIOD_MINUTES}"}