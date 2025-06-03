*** Settings ***
Documentation       Queries the health status of an Function App, and returns 0 when it's not healthy, and 1 when it is.
Metadata            Author    stewartshea
Metadata            Display Name    Azure Function App Triage
Metadata            Supports    Azure    AppService    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check for Resource Health Issues Affecting Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch a list of issues that might affect the Function App as reported from Azure. 
    [Tags]    aks    resource    health    service    azure
    ${resource_health}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_resource_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true

    ${resource_health_output}=    RW.CLI.Run Cli
    ...    cmd=cat function_app_health.json | tr -d '\n'
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


Check Function App `${FUNCTION_APP_NAME}` Health Check Metrics In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks the health check metric of a appservice workload. If issues are generated with severity 1 or 2, the score is 0 / unhealthy. 
    [Tags]    healthcheck    metric    appservice   
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_health_metric.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat function_app_health_check_issues.json
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
Check Function App `${FUNCTION_APP_NAME}` Configuration Health In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks the configuration health of a appservice workload. 1 = healthy, 0 = unhealthy. 
    [Tags]    appservice    configuration    health
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_config_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat az_function_app_config_health.json
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
Check Deployment Health of Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch deployment health of the Function App
    [Tags]    appservice    deployment
    ${deployment_health}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_deployment_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat deployment_health.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    Set Global Variable     ${app_service_deployment_score}    1
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            IF    ${item["severity"]} == 1 or ${item["severity"]} == 2
                Set Global Variable    ${app_service_deployment_score}    0
                Exit For Loop
            ELSE IF    ${item["severity"]} > 2
                Set Global Variable    ${app_service_deployment_score}    1
            END
        END
    END

Fetch Function App `${FUNCTION_APP_NAME}` Activities In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Gets the events of appservice and checks for errors
    [Tags]    appservice    monitor    events    errors
    ${activities}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_activities.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${activities.stdout}

    ${issues}=    RW.CLI.Run Cli    
    ...    cmd=cat function_app_activities_issues.json
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


# Check Logs for Errors in Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
#     [Documentation]    Gets the events of appservice and checks for errors
#     [Tags]    appservice    logs    errors    access:read-only
#     ${log_errors}=    RW.CLI.Run Bash File
#     ...    bash_file=appservice_log_analysis.sh
#     ...    env=${env}
#     ...    timeout_seconds=180
#     ...    include_in_history=false
#     RW.Core.Add Pre To Report    ${log_errors.stdout}

#     ${issues}=    RW.CLI.Run Cli    
#     ...    cmd=cat function_app_log_issues_report.json
#     ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json

#     Set Global Variable     ${app_service_log_error_score}    1
#     IF    len(@{issue_list["issues"]}) > 0
#         FOR    ${item}    IN    @{issue_list["issues"]}
#             IF    ${item["severity"]} != 4
#                 Set Global Variable    ${app_service_log_error_score}    0
#                 Exit For Loop
#             ELSE IF    ${item["severity"]} > 2
#                 Set Global Variable    ${app_service_log_error_score}    1
#             END
#         END
#     END



Generate Function App Health Score for `${FUNCTION_APP_NAME}` in resource group `${AZ_RESOURCE_GROUP}`
    ${app_service_health_score}=      Evaluate  (${appservice_resource_score} + ${app_service_health_check_score} + ${app_service_config_score} + ${app_service_activities_score} + ${app_service_deployment_score}) / 5
    ${health_score}=      Convert to Number    ${app_service_health_score}  2
    RW.Core.Push Metric    ${health_score}


*** Keywords ***
Suite Initialization
    ${AZ_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZ_RESOURCE_GROUP
    ...    type=string
    ...    description=The resource group to perform actions against.
    ...    pattern=\w*
    ${FUNCTION_APP_NAME}=    RW.Core.Import User Variable    FUNCTION_APP_NAME
    ...    type=string
    ...    description=The Azure AppService to triage.
    ...    pattern=\w*
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    ${AZURE_RESOURCE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_RESOURCE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure subscription ID to use for resource operations.
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
    ${REQUESTS_THRESHOLD}=    RW.Core.Import User Variable    REQUESTS_THRESHOLD
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
    ...    description=The threshold of average response time (ms) in which to generate an issue. Higher than this value indicates slow response time.
    ...    pattern=\w*
    ...    default=300
    Set Suite Variable    ${FUNCTION_APP_NAME}    ${FUNCTION_APP_NAME}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable    ${AZURE_RESOURCE_SUBSCRIPTION_ID}    ${AZURE_RESOURCE_SUBSCRIPTION_ID}
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
    ...    {"FUNCTION_APP_NAME":"${FUNCTION_APP_NAME}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}", "AZURE_RESOURCE_SUBSCRIPTION_ID":"${AZURE_RESOURCE_SUBSCRIPTION_ID}", "TIME_PERIOD_MINUTES":"${TIME_PERIOD_MINUTES}","CPU_THRESHOLD":"${CPU_THRESHOLD}", "REQUESTS_THRESHOLD":"${REQUESTS_THRESHOLD}", "BYTES_RECEIVED_THRESHOLD":"${BYTES_RECEIVED_THRESHOLD}", "HTTP5XX_THRESHOLD":"${HTTP5XX_THRESHOLD}","HTTP2XX_THRESHOLD":"${HTTP2XX_THRESHOLD}", "HTTP4XX_THRESHOLD":"${HTTP4XX_THRESHOLD}", "DISK_USAGE_THRESHOLD":"${DISK_USAGE_THRESHOLD}", "AVG_RSP_TIME":"${AVG_RSP_TIME}"}