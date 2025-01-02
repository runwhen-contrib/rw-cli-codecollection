*** Settings ***
Documentation       Queries the health status of an App Service, and returns 0 when it's not healthy, and 1 when it is.
Metadata            Author    stewartshea
Metadata            Display Name    Azure App Service Triage
Metadata            Supports    Azure    App Service    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check for Resource Health Issues Affecting App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch a list of issues that might affect the APP Service as reported from Azure. 
    [Tags]    aks    resource    health    service    azure
    ${resource_health}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_resource_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true

    ${resource_health_output}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/app_service_health.json | tr -d '\n'
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${resource_health_output_json}=    Evaluate    json.loads(r'''${resource_health_output.stdout}''')    json
    IF    len(@{resource_health_output_json}) > 0 
        ${appservice_resource_score}=    Evaluate    1 if "${resource_health_output_json["properties"]["title"]}" == "Available" else 0
    ELSE
        ${appservice_resource_score}=    Set Variable    0
    END
    Set Global Variable    ${appservice_resource_score}


Check App Service `${APP_SERVICE_NAME}` Health Check Metrics In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks the health check metric of a appservice workload. If issues are generated with severity 1 or 2, the score is 0 / unhealthy. 
    [Tags]    healthcheck    metric    appservice   
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_health_metric.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/app_service_health_check_issues.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    Set Global Variable     ${app_service_health_check_score}    1
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            IF    ${item["severity"]} == 1 or ${item["severity"]} == 2
                Set Global Variable    ${app_service_health_check_score}    0
                Exit For Loop
            ELSE IF    ${item["severity"]} > 2
                Set Global Variable    ${app_service_health_check_score}    1
            END
        END
    END
Check App Service `${APP_SERVICE_NAME}` Configuration Health In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks the configuration health of a appservice workload. 1 = healthy, 0 = unhealthy. 
    [Tags]    appservice    configuration    health
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_config_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/az_app_service_health.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    Set Global Variable     ${app_service_config_score}    1
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            IF    ${item["severity"]} == 1 or ${item["severity"]} == 2
                Set Global Variable    ${app_service_config_score}    0
                Exit For Loop
            ELSE IF    ${item["severity"]} > 2
                Set Global Variable    ${app_service_config_score}    1
            END
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
    Set Global Variable     ${app_service_activities_score}    1
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            IF    ${item["severity"]} == 1 or ${item["severity"]} == 2
                Set Global Variable    ${app_service_activities_score}    0
                Exit For Loop
            ELSE IF    ${item["severity"]} > 2
                Set Global Variable    ${app_service_activities_score}    1
            END
        END
    END

Generate App Service Health Score
    ${app_service_health_score}=      Evaluate  (${appservice_resource_score} + ${app_service_health_check_score} + ${app_service_config_score} + ${app_service_activities_score}) / 4
    ${health_score}=      Convert to Number    ${app_service_health_score}  2
    RW.Core.Push Metric    ${health_score}


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
    ${CPU_THRESHOLD}=    RW.Core.Import User Variable    CPU_THRESHOLD
    ...    type=string
    ...    description=The CPU % threshold in which to generate an issue.
    ...    pattern=\w*
    ...    default=80
    ${REQUESTS_THRESHOLD}=    RW.Core.Import User Variable    CPU_THRESHOLD
    ...    type=string
    ...    description=The threshold of requests/s in which to generate an issue.
    ...    pattern=\w*
    ...    default=1000
    ${BYTES_RECEIVED_THRESHOLD}=    RW.Core.Import User Variable    BYTES_RECEIVED_THRESHOLD
    ...    type=string
    ...    description=The threshold of received bytes/s in which to generate an issue.
    ...    pattern=\w*
    ...    default=10485760
    ${HTTP5XX_THRESHOLD}=    RW.Core.Import User Variable    HTTP5XX_THRESHOLD
    ...    type=string
    ...    description=The threshold of HTTP5XX/s in which to generate an issue. Higher than this value indicates a high error rate.
    ...    pattern=\w*
    ...    default=5
    ${HTTP2XX_THRESHOLD}=    RW.Core.Import User Variable    HTTP2XX_THRESHOLD
    ...    type=string
    ...    description=The threshold of HTTP2XX/s in which to generate an issue. Less than this value indicates low success rate.
    ...    pattern=\w*
    ...    default=50
    ${HTTP4XX_THRESHOLD}=    RW.Core.Import User Variable    HTTP4XX_THRESHOLD
    ...    type=string
    ...    description=The threshold of HTTP4XX/s in which to generate an issue. Higher than this value indicates high client error rate.
    ...    pattern=\w*
    ...    default=200
    ${DISK_USAGE_THRESHOLD}=    RW.Core.Import User Variable    DISK_USAGE_THRESHOLD
    ...    type=string
    ...    description=The threshold of disk usage % in which to generate an issue.
    ...    pattern=\w*
    ...    default=90
    ${AVG_RSP_TIME}=    RW.Core.Import User Variable    AVG_RSP_TIME
    ...    type=string
    ...    description=The threshold of average response time in which to generate an issue. Higher than this value indicates slow response time.
    ...    pattern=\w*
    ...    default=20
    Set Suite Variable    ${APP_SERVICE_NAME}    ${APP_SERVICE_NAME}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable    ${TIME_PERIOD_MINUTES}    ${TIME_PERIOD_MINUTES}
    Set Suite Variable    ${CPU_THRESHOLD}    ${CPU_THRESHOLD}
    Set Suite Variable    ${REQUESTS_THRESHOLD}    ${REQUESTS_THRESHOLD}
    Set Suite Variable    ${BYTES_RECEIVED_THRESHOLD}    ${BYTES_RECEIVED_THRESHOLD}
    Set Suite Variable    ${HTTP5XX_THRESHOLD}    ${HTTP5XX_THRESHOLD}
    Set Suite Variable    ${HTTP2XX_THRESHOLD}    ${HTTP2XX_THRESHOLD}
    Set Suite Variable    ${HTTP4XX_THRESHOLD}    ${HTTP4XX_THRESHOLD}
    Set Suite Variable    ${DISK_USAGE_THRESHOLD}    ${DISK_USAGE_THRESHOLD}
    Set Suite Variable    ${AVG_RSP_TIME}    ${AVG_RSP_TIME}

    Set Suite Variable
    ...    ${env}
    ...    {"APP_SERVICE_NAME":"${APP_SERVICE_NAME}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}", "OUTPUT_DIR":"${OUTPUT DIR}", "TIME_PERIOD_MINUTES":"${TIME_PERIOD_MINUTES}","CPU_THRESHOLD":"${CPU_THRESHOLD}", "REQUESTS_THRESHOLD":"${REQUESTS_THRESHOLD}", "BYTES_RECEIVED_THRESHOLD":"${BYTES_RECEIVED_THRESHOLD}", "HTTP5XX_THRESHOLD":"${HTTP5XX_THRESHOLD}","HTTP2XX_THRESHOLD":"${HTTP2XX_THRESHOLD}", "HTTP4XX_THRESHOLD":"${HTTP4XX_THRESHOLD}", "DISK_USAGE_THRESHOLD":"${DISK_USAGE_THRESHOLD}", "AVG_RSP_TIME":"${AVG_RSP_TIME}"}