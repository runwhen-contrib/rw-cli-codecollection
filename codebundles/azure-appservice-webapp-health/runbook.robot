*** Settings ***
Documentation       Triages an Azure App Service and its workloads, checking its status and logs and verifying key metrics.
Metadata            Author    stewartshea
Metadata            Display Name    Azure App Service Webapp Health
Metadata            Supports    Azure    AppService    Triage

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check for Resource Health Issues Affecting App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch a list of issues that might affect the APP Service as reported from Azure. 
    [Tags]    aks    resource    health    service    azure    access:read-only
    ${resource_health}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_resource_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${resource_health.stdout}
    
    # Add portal URL for Resource Health
    ${app_service_resource_id}=    RW.CLI.Run Cli
    ...    cmd=az webapp show --name "${APP_SERVICE_NAME}" --resource-group "${AZ_RESOURCE_GROUP}" --query "id" -o tsv
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    ${resource_health_url}=    Set Variable    https://portal.azure.com/#@/resource${app_service_resource_id.stdout.strip()}/resourceHealth
    RW.Core.Add Pre To Report    🔗 View Resource Health in Azure Portal: ${resource_health_url}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat app_service_health.json 
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0 
        IF    "${issue_list["properties"]["title"]}" != "Available"
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=Azure resources should be available for APP Service`${APP_SERVICE_NAME}` in `${AZ_RESOURCE_GROUP}`
            ...    actual=Azure resources are unhealthy for APP Service`${APP_SERVICE_NAME}` in `${AZ_RESOURCE_GROUP}`
            ...    title=Azure reports an `${issue_list["properties"]["title"]}` Issue for APP Service`${APP_SERVICE_NAME}` in `${AZ_RESOURCE_GROUP}`
            ...    reproduce_hint=${resource_health.cmd}
            ...    details=${issue_list}
            ...    next_steps=Please escalate to the Azure service owner or check back later.
        END
    ELSE
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Azure resources health should be enabled for APP Service`${APP_SERVICE_NAME}` in `${AZ_RESOURCE_GROUP}`
        ...    actual=Azure resource health appears unavailable for APP Service`${APP_SERVICE_NAME}` in `${AZ_RESOURCE_GROUP}`
        ...    title=Azure resource health is unavailable for APP Service`${APP_SERVICE_NAME}` in `${AZ_RESOURCE_GROUP}`
        ...    reproduce_hint=${resource_health.cmd}
        ...    details=${issue_list}
        ...    next_steps=Please escalate to the Azure service owner to enable provider Microsoft.ResourceHealth.
    END


Check App Service `${APP_SERVICE_NAME}` Health in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks the health status of a appservice workload.
    [Tags]    access:read-only    appservice    health
    ${health_check_metric}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_health_metric.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${health_check_metric.stdout}
    
    ${summary}=    RW.CLI.Run Cli
    ...    cmd=cat app_service_health_check_summary.txt
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${summary.stdout}

    ${metrics}=    RW.CLI.Run Cli
    ...    cmd=cat app_service_health_check_metrics.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${metrics.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat app_service_health_check_issues.json
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
    
    # Add portal URL for Health Check configuration
    ${app_service_resource_id_health}=    RW.CLI.Run Cli
    ...    cmd=az webapp show --name "${APP_SERVICE_NAME}" --resource-group "${AZ_RESOURCE_GROUP}" --query "id" -o tsv
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    ${health_check_url}=    Set Variable    https://portal.azure.com/#@/resource${app_service_resource_id_health.stdout.strip()}/healthcheck
    RW.Core.Add Pre To Report    🔗 Configure Health Check in Azure Portal: ${health_check_url}

Fetch App Service `${APP_SERVICE_NAME}` Utilization Metrics In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Reviews all key metrics (CPU, Requests, Bandwidth, HTTP status codes, Threads, Disk, Response Time) for the last 30 minutes with 5-minute intervals
    [Tags]    access:read-only     appservice    utilization    metrics
    ${metric_health}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_metric_health.sh
    ...    env=${env}
    ...    timeout_seconds=90
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${metric_health.stdout}
    ${summary}=    RW.CLI.Run Cli
    ...    cmd=cat app_service_metrics_summary.txt
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${summary.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat app_service_issues.json
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
    
    # Add portal URL for Metrics
    ${app_service_resource_id_metrics}=    RW.CLI.Run Cli
    ...    cmd=az webapp show --name "${APP_SERVICE_NAME}" --resource-group "${AZ_RESOURCE_GROUP}" --query "id" -o tsv
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    ${metrics_url}=    Set Variable    https://portal.azure.com/#@/resource${app_service_resource_id_metrics.stdout.strip()}/metrics
    RW.Core.Add Pre To Report    🔗 View Metrics in Azure Portal: ${metrics_url}

Get App Service `${APP_SERVICE_NAME}` Logs In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch enhanced logs of appservice workload (application-level, Docker, deployment, performance traces - optimized for report size)
    [Tags]    appservice    logs    enhanced    filtered    access:read-only
    ${logs}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_logs.sh
    ...    env=${env}
    ...    timeout_seconds=90
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${logs.stdout}
    
    # Add portal URL for Logs
    ${app_service_resource_id_logs}=    RW.CLI.Run Cli
    ...    cmd=az webapp show --name "${APP_SERVICE_NAME}" --resource-group "${AZ_RESOURCE_GROUP}" --query "id" -o tsv
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    ${logs_url}=    Set Variable    https://portal.azure.com/#@/resource${app_service_resource_id_logs.stdout.strip()}/logStream
    RW.Core.Add Pre To Report    🔗 View Log Stream in Azure Portal: ${logs_url}

Check Configuration Health of App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch the configuration health of the App Service
    [Tags]    appservice    logs    tail    access:read-only
    ${config_health}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_config_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${config_health.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat az_app_service_health.json
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
    
    # Add portal URL for Configuration
    ${app_service_resource_id_config}=    RW.CLI.Run Cli
    ...    cmd=az webapp show --name "${APP_SERVICE_NAME}" --resource-group "${AZ_RESOURCE_GROUP}" --query "id" -o tsv
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    ${config_url}=    Set Variable    https://portal.azure.com/#@/resource${app_service_resource_id_config.stdout.strip()}/configuration
    RW.Core.Add Pre To Report    🔗 View Configuration in Azure Portal: ${config_url}

Check Deployment Health of App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch deployment health of the App Service
    [Tags]    appservice    deployment    access:read-only
    ${deployment_health}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_deployment_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${deployment_health.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat deployment_health.json
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
            ...    expected=App Service `${APP_SERVICE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has a healthy deployments
            ...    actual=App Service `${APP_SERVICE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has deployment issues
            ...    reproduce_hint=${deployment_health.cmd}
            ...    details=${item["details"]}        
        END
    END
    
    # Add portal URL for Deployment Center
    ${app_service_resource_id_deployment}=    RW.CLI.Run Cli
    ...    cmd=az webapp show --name "${APP_SERVICE_NAME}" --resource-group "${AZ_RESOURCE_GROUP}" --query "id" -o tsv
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    ${deployment_url}=    Set Variable    https://portal.azure.com/#@/resource${app_service_resource_id_deployment.stdout.strip()}/deployment
    RW.Core.Add Pre To Report    🔗 View Deployment Center in Azure Portal: ${deployment_url}

Fetch App Service `${APP_SERVICE_NAME}` Activities In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Gets the events of appservice and checks for errors
    [Tags]    appservice    monitor    events    errors    access:read-only
    ${activities}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_activities.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${activities.stdout}

    ${issues}=    RW.CLI.Run Cli    
    ...    cmd=cat app_service_activities_issues.json
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
    
    # Add portal URL for Activity Log
    ${app_service_resource_id_activity}=    RW.CLI.Run Cli
    ...    cmd=az webapp show --name "${APP_SERVICE_NAME}" --resource-group "${AZ_RESOURCE_GROUP}" --query "id" -o tsv
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    ${activity_url}=    Set Variable    https://portal.azure.com/#@/resource${app_service_resource_id_activity.stdout.strip()}/activitylog
    RW.Core.Add Pre To Report    🔗 View Activity Log in Azure Portal: ${activity_url}

Check Logs for Errors in App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Analyze App Service logs for errors using Azure Monitor APIs and Application Insights - creates structured issues for detected problems
    [Tags]    appservice    logs    errors    analysis    azure-monitor    access:read-only
    ${log_errors}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_log_analysis.sh
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${log_errors.stdout}

    IF    "${log_errors.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Error Running Log Analysis Script
        ...    severity=3
        ...    next_steps=Review debug logs in report
        ...    expected=No stderr output
        ...    actual=stderr encountered
        ...    reproduce_hint=${log_errors.cmd}
        ...    details=${log_errors.stderr}
    END

    ${issues}=    RW.CLI.Run Cli    
    ...    cmd=cat app_service_log_issues_report.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_steps"]}
            ...    expected=App Service `${APP_SERVICE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has no critical errors in logs
            ...    actual=App Service `${APP_SERVICE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has errors detected in logs
            ...    reproduce_hint=${log_errors.cmd}
            ...    details=${item["details"]}        
        END
    END
    
    # Add portal URL for Log Analytics and Diagnostics
    ${app_service_resource_id_analytics}=    RW.CLI.Run Cli
    ...    cmd=az webapp show --name "${APP_SERVICE_NAME}" --resource-group "${AZ_RESOURCE_GROUP}" --query "id" -o tsv
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    ${log_analytics_url}=    Set Variable    https://portal.azure.com/#@/resource${app_service_resource_id_analytics.stdout.strip()}/diagnostics
    RW.Core.Add Pre To Report    🔗 View Diagnostics and Log Analytics in Azure Portal: ${log_analytics_url}

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
    ${AZURE_RESOURCE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_RESOURCE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure Subscription ID for the resource.
    ...    pattern=\w*
    ...    default=""
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
    ${LOG_LEVEL}=    RW.Core.Import User Variable    LOG_LEVEL
    ...    type=string
    ...    description=Log verbosity level: ERROR, WARN, INFO, DEBUG, VERBOSE
    ...    pattern=\w*
    ...    default=INFO
    ${MAX_LOG_LINES}=    RW.Core.Import User Variable    MAX_LOG_LINES
    ...    type=string
    ...    description=Maximum lines per log file to display
    ...    pattern=\w*
    ...    default=100
    ${INCLUDE_DOCKER_LOGS}=    RW.Core.Import User Variable    INCLUDE_DOCKER_LOGS
    ...    type=string
    ...    description=Include Docker container logs in output (true/false)
    ...    pattern=\w*
    ...    default=true
    ${INCLUDE_DEPLOYMENT_LOGS}=    RW.Core.Import User Variable    INCLUDE_DEPLOYMENT_LOGS
    ...    type=string
    ...    description=Include deployment history logs in output (true/false)
    ...    pattern=\w*
    ...    default=true
    ${INCLUDE_PERFORMANCE_TRACES}=    RW.Core.Import User Variable    INCLUDE_PERFORMANCE_TRACES
    ...    type=string
    ...    description=Include performance traces in output (true/false)
    ...    pattern=\w*
    ...    default=false
    Set Suite Variable    ${APP_SERVICE_NAME}    ${APP_SERVICE_NAME}
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
    Set Suite Variable    ${LOG_LEVEL}    ${LOG_LEVEL}
    Set Suite Variable    ${MAX_LOG_LINES}    ${MAX_LOG_LINES}
    Set Suite Variable    ${INCLUDE_DOCKER_LOGS}    ${INCLUDE_DOCKER_LOGS}
    Set Suite Variable    ${INCLUDE_DEPLOYMENT_LOGS}    ${INCLUDE_DEPLOYMENT_LOGS}
    Set Suite Variable    ${INCLUDE_PERFORMANCE_TRACES}    ${INCLUDE_PERFORMANCE_TRACES}

    Set Suite Variable
    ...    ${env}
    ...    {"APP_SERVICE_NAME":"${APP_SERVICE_NAME}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}", "AZURE_RESOURCE_SUBSCRIPTION_ID":"${AZURE_RESOURCE_SUBSCRIPTION_ID}", "TIME_PERIOD_MINUTES":"${TIME_PERIOD_MINUTES}","CPU_THRESHOLD":"${CPU_THRESHOLD}", "REQUESTS_THRESHOLD":"${REQUESTS_THRESHOLD}", "BYTES_RECEIVED_THRESHOLD":"${BYTES_RECEIVED_THRESHOLD}", "HTTP5XX_THRESHOLD":"${HTTP5XX_THRESHOLD}","HTTP2XX_THRESHOLD":"${HTTP2XX_THRESHOLD}", "HTTP4XX_THRESHOLD":"${HTTP4XX_THRESHOLD}", "DISK_USAGE_THRESHOLD":"${DISK_USAGE_THRESHOLD}", "AVG_RSP_TIME":"${AVG_RSP_TIME}", "LOG_LEVEL":"${LOG_LEVEL}", "MAX_LOG_LINES":"${MAX_LOG_LINES}", "INCLUDE_DOCKER_LOGS":"${INCLUDE_DOCKER_LOGS}", "INCLUDE_DEPLOYMENT_LOGS":"${INCLUDE_DEPLOYMENT_LOGS}", "INCLUDE_PERFORMANCE_TRACES":"${INCLUDE_PERFORMANCE_TRACES}"}
