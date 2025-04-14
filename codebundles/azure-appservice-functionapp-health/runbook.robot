*** Settings ***
Documentation       Triages an Azure Function App and its workloads, checking its status and logs and verifying key metrics.
Metadata            Author    stewartshea
Metadata            Display Name    Azure Function App Health
Metadata            Supports    Azure    AppService    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check for Resource Health Issues Affecting Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch a list of issues that might affect the Function App as reported from Azure. 
    [Tags]    aks    resource    health    service    azure    access:read-only
    ${resource_health}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_resource_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${resource_health.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat function_app_health.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0 
        IF    "${issue_list["properties"]["title"]}" != "Available"
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=Azure resources should be available for Function App`${FUNCTION_APP_NAME}` in `${AZ_RESOURCE_GROUP}`
            ...    actual=Azure resources are unhealthy for Function App`${FUNCTION_APP_NAME}` in `${AZ_RESOURCE_GROUP}`
            ...    title=Azure reports an `${issue_list["properties"]["title"]}` Issue for Function App`${FUNCTION_APP_NAME}` in `${AZ_RESOURCE_GROUP}`
            ...    reproduce_hint=${resource_health.cmd}
            ...    details=${issue_list}
            ...    next_steps=Please escalate to the Azure service owner or check back later.
        END
    ELSE
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Azure resources health should be enabled for Function App`${FUNCTION_APP_NAME}` in `${AZ_RESOURCE_GROUP}`
        ...    actual=Azure resource health appears unavailable for Function App`${FUNCTION_APP_NAME}` in `${AZ_RESOURCE_GROUP}`
        ...    title=Azure resource health is unavailable for Function App`${FUNCTION_APP_NAME}` in `${AZ_RESOURCE_GROUP}`
        ...    reproduce_hint=${resource_health.cmd}
        ...    details=${issue_list}
        ...    next_steps=Please escalate to the Azure service owner to enable provider Microsoft.ResourceHealth.
    END


Check Function App `${FUNCTION_APP_NAME}` Health in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks the health status of a appservice workload.
    [Tags]    access:read-only    appservice    health
    ${health_check_metric}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_health_metric.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${health_check_metric.stdout}
    
    ${summary}=    RW.CLI.Run Cli
    ...    cmd=cat function_app_health_check_summary.txt
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${summary.stdout}

    ${metrics}=    RW.CLI.Run Cli
    ...    cmd=cat function_app_health_check_metrics.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${metrics.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat function_app_health_check_issues.json
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
            ...    expected=Function App `${FUNCTION_APP_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has is reported healthy
            ...    actual=Function App `${FUNCTION_APP_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has health check metric issues
            ...    reproduce_hint=${health_check_metric.cmd}
            ...    details=${item["details"]}        
        END
    END
    RW.Core.Add Pre To Report    ${health_check_metric.stdout}

Fetch Function App `${FUNCTION_APP_NAME}` Plan Utilization Metrics In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Reviews key metrics for the Function App plan and generates a report
    [Tags]    access:read-only     appservice    utilization
    ${metric_health}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_plan_utilization_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${metric_health.stdout}
    ${summary}=    RW.CLI.Run Cli
    ...    cmd=cat function_app_plan_summary.txt
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${summary.stdout}

    ${metrics}=    RW.CLI.Run Cli
    ...    cmd=cat function_app_plan_metrics.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${metrics.stdout}


    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat function_app_plan_issues.json
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
            ...    expected=Function App `${FUNCTION_APP_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has healthy metrics
            ...    actual=Function App `${FUNCTION_APP_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has metric issues
            ...    reproduce_hint=${metric_health.cmd}
            ...    details=${item["details"]}        
        END
    END


Get Function App `${FUNCTION_APP_NAME}` Logs In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch logs of appservice workload
    [Tags]    appservice    logs    tail    access:read-only
    ${logs}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_logs.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${logs.stdout}

Check Configuration Health of Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch the configuration health of the Function App
    [Tags]    appservice    logs    tail    access:read-only
    ${config_health}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_config_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${config_health.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat az_function_app_config_health.json
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
            ...    expected=Function App `${FUNCTION_APP_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has a healthy configuration
            ...    actual=Function App `${FUNCTION_APP_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has configuration reccomentations
            ...    reproduce_hint=${config_health.cmd}
            ...    details=${item["details"]}        
        END
    END

Check Deployment Health of Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch deployment health of the Function App
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
            ...    expected=Function App `${FUNCTION_APP_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has a healthy deployments
            ...    actual=Function App `${FUNCTION_APP_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has deployment issues
            ...    reproduce_hint=${deployment_health.cmd}
            ...    details=${item["details"]}        
        END
    END

Fetch Function App `${FUNCTION_APP_NAME}` Activities In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Gets the events of appservice and checks for errors
    [Tags]    appservice    monitor    events    errors    access:read-only
    ${activities}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_activities.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${activities.stdout}

    ${issues}=    RW.CLI.Run Cli    
    ...    cmd=cat function_app_activities_issues.json
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=Function App `${FUNCTION_APP_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has no Warning/Error/Critical activities
            ...    actual=Function App `${FUNCTION_APP_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has Warning/Error/Critical activities
            ...    reproduce_hint=${activities.cmd}
            ...    details=${item["details"]}        
        END
    END
Check Logs for Errors in Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Gets the events of appservice and checks for errors
    [Tags]    appservice    logs    errors    access:read-only
    ${log_errors}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_log_analysis.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${log_errors.stdout}

    ${issues}=    RW.CLI.Run Cli    
    ...    cmd=cat function_app_log_issues_report.json
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=Function App `${FUNCTION_APP_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has no Warning/Error/Critical logs
            ...    actual=Function App `${FUNCTION_APP_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has Warning/Error/Critical logs
            ...    reproduce_hint=${log_errors.cmd}
            ...    details=${item["details"]}        
        END
    END

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
    ...    {"FUNCTION_APP_NAME":"${FUNCTION_APP_NAME}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}", "TIME_PERIOD_MINUTES":"${TIME_PERIOD_MINUTES}","CPU_THRESHOLD":"${CPU_THRESHOLD}", "REQUESTS_THRESHOLD":"${REQUESTS_THRESHOLD}", "BYTES_RECEIVED_THRESHOLD":"${BYTES_RECEIVED_THRESHOLD}", "HTTP5XX_THRESHOLD":"${HTTP5XX_THRESHOLD}","HTTP2XX_THRESHOLD":"${HTTP2XX_THRESHOLD}", "HTTP4XX_THRESHOLD":"${HTTP4XX_THRESHOLD}", "DISK_USAGE_THRESHOLD":"${DISK_USAGE_THRESHOLD}", "AVG_RSP_TIME":"${AVG_RSP_TIME}"}