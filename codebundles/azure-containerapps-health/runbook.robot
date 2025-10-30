*** Settings ***
Documentation       Triages an Azure Container App and its workloads, checking its status, logs, metrics, and verifying key configuration.
Metadata            Author    stewartshea
Metadata            Display Name    Azure Container Apps Health Monitoring
Metadata            Supports    Azure    ContainerApps    Health    Monitoring

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check for Resource Health Issues Affecting Container App `${CONTAINER_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch a list of issues that might affect the Container App as reported from Azure. 
    [Tags]    containerapp    resource    health    azure    access:read-only
    ${resource_health}=    RW.CLI.Run Bash File
    ...    bash_file=containerapp_resource_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${resource_health.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat container_app_health.json 
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0 
        IF    "${issue_list["properties"]["title"]}" != "Available"
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=Azure resources should be available for Container App `${CONTAINER_APP_NAME}` in `${AZ_RESOURCE_GROUP}`
            ...    actual=Azure resources are unhealthy for Container App `${CONTAINER_APP_NAME}` in `${AZ_RESOURCE_GROUP}`
            ...    title=Azure reports an `${issue_list["properties"]["title"]}` Issue for Container App `${CONTAINER_APP_NAME}` in `${AZ_RESOURCE_GROUP}`
            ...    reproduce_hint=${resource_health.cmd}
            ...    details=${issue_list}
            ...    next_steps=Please escalate to the Azure service owner or check back later.
        END
    ELSE
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Azure resource health should be enabled for Container App `${CONTAINER_APP_NAME}` in `${AZ_RESOURCE_GROUP}`
        ...    actual=Azure resource health appears unavailable for Container App `${CONTAINER_APP_NAME}` in `${AZ_RESOURCE_GROUP}`
        ...    title=Azure resource health is unavailable for Container App `${CONTAINER_APP_NAME}` in `${AZ_RESOURCE_GROUP}`
        ...    reproduce_hint=${resource_health.cmd}
        ...    details=${issue_list}
        ...    next_steps=Please escalate to the Azure service owner to enable provider Microsoft.ResourceHealth.
    END

Check Container App `${CONTAINER_APP_NAME}` Replica Health in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks the health status and replica count of the container app workload.
    [Tags]    access:read-only    containerapp    health    replicas
    ${replica_health}=    RW.CLI.Run Bash File
    ...    bash_file=containerapp_replica_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${replica_health.stdout}
    
    ${summary}=    RW.CLI.Run Cli
    ...    cmd=cat container_app_replica_summary.txt
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${summary.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat container_app_replica_issues.json
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
            ...    expected=Container App `${CONTAINER_APP_NAME}` in resource group `${AZ_RESOURCE_GROUP}` should have healthy replicas
            ...    actual=Container App `${CONTAINER_APP_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has replica health issues
            ...    reproduce_hint=${replica_health.cmd}
            ...    details=${item["details"]}        
        END
    END

Fetch Container App `${CONTAINER_APP_NAME}` Utilization Metrics In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Reviews key metrics for the container app and generates a report
    [Tags]    access:read-only     containerapp    utilization    metrics
    ${metric_health}=    RW.CLI.Run Bash File
    ...    bash_file=containerapp_metric_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${metric_health.stdout}
    
    ${summary}=    RW.CLI.Run Cli
    ...    cmd=cat container_app_metrics_summary.txt
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${summary.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat container_app_metrics_issues.json
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
            ...    expected=Container App `${CONTAINER_APP_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has healthy metrics
            ...    actual=Container App `${CONTAINER_APP_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has metric issues
            ...    reproduce_hint=${metric_health.cmd}
            ...    details=${item["details"]}        
        END
    END

Get Container App `${CONTAINER_APP_NAME}` Logs In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch logs of container app workload
    [Tags]    containerapp    logs    tail    access:read-only
    ${logs}=    RW.CLI.Run Bash File
    ...    bash_file=containerapp_logs.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${logs.stdout}

Check Configuration Health of Container App `${CONTAINER_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch the configuration health of the Container App including environment and scaling configuration
    [Tags]    containerapp    config    health    access:read-only
    ${config_health}=    RW.CLI.Run Bash File
    ...    bash_file=containerapp_config_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${config_health.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat container_app_config_issues.json
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
            ...    expected=Container App `${CONTAINER_APP_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has a healthy configuration
            ...    actual=Container App `${CONTAINER_APP_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has configuration recommendations
            ...    reproduce_hint=${config_health.cmd}
            ...    details=${item["details"]}        
        END
    END

Check Revision Health of Container App `${CONTAINER_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch revision health and deployment status of the Container App
    [Tags]    containerapp    revision    deployment    access:read-only
    ${revision_health}=    RW.CLI.Run Bash File
    ...    bash_file=containerapp_revision_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${revision_health.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat container_app_revision_issues.json
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
            ...    expected=Container App `${CONTAINER_APP_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has healthy revisions
            ...    actual=Container App `${CONTAINER_APP_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has revision issues
            ...    reproduce_hint=${revision_health.cmd}
            ...    details=${item["details"]}        
        END
    END

Check Container App Environment `${CONTAINER_APP_ENV_NAME}` Health In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Monitors the health of the Container Apps Environment including networking and infrastructure
    [Tags]    containerapp    environment    networking    access:read-only
    ${env_health}=    RW.CLI.Run Bash File
    ...    bash_file=containerapp_environment_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${env_health.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat container_app_env_issues.json
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
            ...    expected=Container Apps Environment `${CONTAINER_APP_ENV_NAME}` in resource group `${AZ_RESOURCE_GROUP}` should be healthy
            ...    actual=Container Apps Environment `${CONTAINER_APP_ENV_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has health issues
            ...    reproduce_hint=${env_health.cmd}
            ...    details=${item["details"]}        
        END
    END

Check Logs for Errors in Container App `${CONTAINER_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Analyzes container app logs for errors and warnings
    [Tags]    containerapp    logs    errors    access:read-only
    ${log_errors}=    RW.CLI.Run Bash File
    ...    bash_file=containerapp_log_analysis.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${log_errors.stdout}

    ${issues}=    RW.CLI.Run Cli    
    ...    cmd=cat container_app_log_issues.json
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
            ...    expected=Container App `${CONTAINER_APP_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has no Warning/Error/Critical logs
            ...    actual=Container App `${CONTAINER_APP_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has Warning/Error/Critical logs
            ...    reproduce_hint=${log_errors.cmd}
            ...    details=${item["details"]}        
        END
    END

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
    ${CONTAINER_APP_ENV_NAME}=    RW.Core.Import User Variable    CONTAINER_APP_ENV_NAME
    ...    type=string
    ...    description=The Container Apps Environment name.
    ...    pattern=\w*
    ...    default=""
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
    ...    description=The time period, in minutes, to look back for metrics and logs. 
    ...    pattern=\w*
    ...    default=10
    ${CPU_THRESHOLD}=    RW.Core.Import User Variable    CPU_THRESHOLD
    ...    type=string
    ...    description=The CPU % threshold in which to generate an issue.
    ...    pattern=\w*
    ...    default=80
    ${MEMORY_THRESHOLD}=    RW.Core.Import User Variable    MEMORY_THRESHOLD
    ...    type=string
    ...    description=The memory % threshold in which to generate an issue.
    ...    pattern=\w*
    ...    default=80
    ${REPLICA_COUNT_MIN}=    RW.Core.Import User Variable    REPLICA_COUNT_MIN
    ...    type=string
    ...    description=The minimum expected replica count.
    ...    pattern=\w*
    ...    default=1
    ${RESTART_COUNT_THRESHOLD}=    RW.Core.Import User Variable    RESTART_COUNT_THRESHOLD
    ...    type=string
    ...    description=The restart count threshold to generate an issue.
    ...    pattern=\w*
    ...    default=5
    ${REQUEST_COUNT_THRESHOLD}=    RW.Core.Import User Variable    REQUEST_COUNT_THRESHOLD
    ...    type=string
    ...    description=The request count per minute threshold.
    ...    pattern=\w*
    ...    default=1000
    ${HTTP_ERROR_RATE_THRESHOLD}=    RW.Core.Import User Variable    HTTP_ERROR_RATE_THRESHOLD
    ...    type=string
    ...    description=The HTTP error rate percentage threshold.
    ...    pattern=\w*
    ...    default=5

    Set Suite Variable    ${CONTAINER_APP_NAME}    ${CONTAINER_APP_NAME}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable    ${CONTAINER_APP_ENV_NAME}    ${CONTAINER_APP_ENV_NAME}
    Set Suite Variable    ${AZURE_RESOURCE_SUBSCRIPTION_ID}    ${AZURE_RESOURCE_SUBSCRIPTION_ID}
    Set Suite Variable    ${TIME_PERIOD_MINUTES}    ${TIME_PERIOD_MINUTES}
    Set Suite Variable    ${CPU_THRESHOLD}    ${CPU_THRESHOLD}
    Set Suite Variable    ${MEMORY_THRESHOLD}    ${MEMORY_THRESHOLD}
    Set Suite Variable    ${REPLICA_COUNT_MIN}    ${REPLICA_COUNT_MIN}
    Set Suite Variable    ${RESTART_COUNT_THRESHOLD}    ${RESTART_COUNT_THRESHOLD}
    Set Suite Variable    ${REQUEST_COUNT_THRESHOLD}    ${REQUEST_COUNT_THRESHOLD}
    Set Suite Variable    ${HTTP_ERROR_RATE_THRESHOLD}    ${HTTP_ERROR_RATE_THRESHOLD}

    Set Suite Variable
    ...    ${env}
    ...    {"CONTAINER_APP_NAME":"${CONTAINER_APP_NAME}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}", "CONTAINER_APP_ENV_NAME":"${CONTAINER_APP_ENV_NAME}", "AZURE_RESOURCE_SUBSCRIPTION_ID":"${AZURE_RESOURCE_SUBSCRIPTION_ID}", "TIME_PERIOD_MINUTES":"${TIME_PERIOD_MINUTES}", "CPU_THRESHOLD":"${CPU_THRESHOLD}", "MEMORY_THRESHOLD":"${MEMORY_THRESHOLD}", "REPLICA_COUNT_MIN":"${REPLICA_COUNT_MIN}", "RESTART_COUNT_THRESHOLD":"${RESTART_COUNT_THRESHOLD}", "REQUEST_COUNT_THRESHOLD":"${REQUEST_COUNT_THRESHOLD}", "HTTP_ERROR_RATE_THRESHOLD":"${HTTP_ERROR_RATE_THRESHOLD}"} 