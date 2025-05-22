*** Settings ***
Documentation       Performs a health check on Azure Application Gateways and the backend pools used by them, generating a report of issues and next steps.
Metadata            Author    stewartshea
Metadata            Display Name    Azure Application Gateway Health
Metadata            Supports    Azure    Application Gateway

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check for Resource Health Issues Affecting Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch a list of issues that might affect the application gateway cluster
    [Tags]    appgateway    resourcehealth   access:read-only
    ${resource_health}=    RW.CLI.Run Bash File
    ...    bash_file=app_gateway_resource_health.sh
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${resource_health.stdout}
    IF    "${resource_health.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Warnings/Errors running task.
        ...    severity=3
        ...    next_steps=Check debug logs in Report
        ...    expected=No stderr output
        ...    actual=stderr encountered
        ...    reproduce_hint=${resource_health.cmd}
        ...    details=${resource_health.stderrt}
    END

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat app_gateway_health.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0 
        IF    "${issue_list["properties"]["title"]}" != "Available"
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=Azure resources should be available for Application Gateway `${APP_GATEWAY_NAME}` in `${AZ_RESOURCE_GROUP}`
            ...    actual=Azure resources are unhealthy for Application Gateway `${APP_GATEWAY_NAME}` in `${AZ_RESOURCE_GROUP}`
            ...    title=Azure reports an `${issue_list["properties"]["title"]}` Issue for Application Gateway `${APP_GATEWAY_NAME}` in `${AZ_RESOURCE_GROUP}`
            ...    reproduce_hint=${resource_health.cmd}
            ...    details=${issue_list}
            ...    next_steps=Please escalate to the Azure service owner or check back later.
        END
    ELSE
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Azure resources health should be enabled for Application Gateway `${APP_GATEWAY_NAME}` in `${AZ_RESOURCE_GROUP}`
        ...    actual=Azure resource health appears unavailable for Application Gateway `${APP_GATEWAY_NAME}` in `${AZ_RESOURCE_GROUP}`
        ...    title=Azure resource health is unavailable for Application Gateway `${APP_GATEWAY_NAME}` in `${AZ_RESOURCE_GROUP}`
        ...    reproduce_hint=${resource_health.cmd}
        ...    details=${issue_list}
        ...    next_steps=Please escalate to the Azure service owner to enable provider Microsoft.ResourceHealth.
    END
Check Configuration Health of Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch the details and health of the application gateway configuration
    [Tags]    appgateway    config    health    access:read-only
    ${config_health}=    RW.CLI.Run Bash File
    ...    bash_file=app_gateway_config_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${config_health.stdout}
    IF    "${config_health.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Warnings/Errors running task.
        ...    severity=3
        ...    next_steps=Check debug logs in Report
        ...    expected=No stderr output
        ...    actual=stderr encountered
        ...    reproduce_hint=${config_health.cmd}
        ...    details=${config_health.stderrt}
    END
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat app_gateway_config_health.json
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
            ...    expected=Application Gateway `${APP_GATEWAY_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has a healthy configuration
            ...    actual=Application Gateway `${APP_GATEWAY_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has configuration recommendations
            ...    reproduce_hint=${config_health.cmd}
            ...    details=${item["details"]}        
        END
    END

Check Backend Pool Health for Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch the health of the application gateway backend pool members
    [Tags]    appgateway    logs    tail    access:read-only
    ${backend_health}=    RW.CLI.Run Bash File
    ...    bash_file=app_gateway_backend_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${backend_health.stdout}
    IF    "${backend_health.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Warnings/Errors running task.
        ...    severity=3
        ...    next_steps=Check debug logs in Report
        ...    expected=No stderr output
        ...    actual=stderr encountered
        ...    reproduce_hint=${backend_health.cmd}
        ...    details=${backend_health.stderr}
    END
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat backend_pool_members_health.json
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
            ...    expected=Application Gateway `${APP_GATEWAY_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has healthy pool members
            ...    actual=Application Gateway `${APP_GATEWAY_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has unhealthy pool members
            ...    reproduce_hint=${backend_health.cmd}
            ...    details=${item["details"]}        
        END
    END   

Fetch Log Analytics for Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch log analytics for the application gateway
    [Tags]    access:read-only  appgateway    logs    analytics    uri_errors    requests    ssl    errors
    ${log_analytics}=    RW.CLI.Run Bash File
    ...    bash_file=app_gateway_log_analytics.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${log_analytics.stdout}
    IF    "${log_analytics.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Warnings/Errors running task.
        ...    severity=3
        ...    next_steps=Check debug logs in Report
        ...    expected=No stderr output
        ...    actual=stderr encountered
        ...    reproduce_hint=${log_analytics.cmd}
        ...    details=${log_analytics.stderr}
    END
    ${analytics}=    RW.CLI.Run Cli
    ...    cmd=cat app_gateway_log_metrics.json | jq . 
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${analytics.stdout}

Fetch Metrics for Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch metrics for the application gateway
    [Tags]    access:read-only  appgateway    metrics    analytics
    ${metrics}=    RW.CLI.Run Bash File
    ...    bash_file=app_gateway_metrics.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${metrics.stdout}
    IF    "${metrics.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Warnings/Errors running task.
        ...    severity=3
        ...    next_steps=Check debug logs in Report
        ...    expected=No stderr output
        ...    actual=stderr encountered
        ...    reproduce_hint=${metrics.cmd}
        ...    details=${metrics.stderr}
    END
    ${metrics_output}=    RW.CLI.Run Cli
    ...    cmd=cat app_gateway_metrics.json | jq '.metrics'
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${metrics_output.stdout}
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat app_gateway_metrics.json | jq '.issues'
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0
        FOR    ${item}    IN    @{issue_list}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=Application Gateway `${APP_GATEWAY_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has healthy metrics
            ...    actual=Application Gateway `${APP_GATEWAY_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has unhealthy metrics
            ...    reproduce_hint=${metrics.cmd}
            ...    details=${item["details"]}        
        END
    END   

Check SSL Certificate Health for Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch SSL certificates and validate expiry dates for Azure Application Gateway instances
    [Tags]    access:read-only  appgateway    ssl    expiry
    ${ssl_health}=    RW.CLI.Run Bash File
    ...    bash_file=app_gateway_ssl_certs.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${ssl_health.stdout}
    IF    "${ssl_health.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Warnings/Errors running task.
        ...    severity=3
        ...    next_steps=Check debug logs in Report
        ...    expected=No stderr output
        ...    actual=stderr encountered
        ...    reproduce_hint=${ssl_health.cmd}
        ...    details=${ssl_health.stderr}
    END
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat appgw_ssl_certificate_checks.json | jq '.issues'
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0
        FOR    ${item}    IN    @{issue_list}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=Application Gateway `${APP_GATEWAY_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has healthy SSL certificates
            ...    actual=Application Gateway `${APP_GATEWAY_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has unhealthy SSL certificates
            ...    reproduce_hint=${ssl_health.cmd}
            ...    details=${item["details"]}        
        END
    END   

Check Logs for Errors with Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Query log analytics workspace for common errors like IP mismatches or subnet issues
    [Tags]    access:read-only  appgateway    logs    network    errors
    ${log_errors}=    RW.CLI.Run Bash File
    ...    bash_file=app_gateway_log_errors.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${log_errors.stdout}
    IF    "${log_errors.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Warnings/Errors running task.
        ...    severity=3
        ...    next_steps=Check debug logs in Report
        ...    expected=No stderr output
        ...    actual=stderr encountered
        ...    reproduce_hint=${log_errors.cmd}
        ...    details=${log_errors.stderr}
    END
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat appgw_diagnostic_log_issues.json | jq '.issues'
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0
        FOR    ${item}    IN    @{issue_list}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=Application Gateway `${APP_GATEWAY_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has no network error logs
            ...    actual=Application Gateway `${APP_GATEWAY_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has error logs
            ...    reproduce_hint=${log_errors.cmd}
            ...    details=${item["details"]}        
        END
    END   

List Related Azure Resources for Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch a list of resources that are releated to the application gateway
    [Tags]    access:read-only  appgateway    resources    azure    related
    ${resources}=    RW.CLI.Run Bash File
    ...    bash_file=app_gateway_related_resources.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${resources.stdout}

    ${resource_table}=    RW.CLI.Run Cli
    ...    cmd=cat appgw_resource_discovery.json | jq -r '.discoveries | (["POOL","ADDRESS","TYPE","RESOURCE_ID"]|@tsv),(["----","----","----","----"]|@tsv),(.[ ]|[.backendPoolName,.address,.resource_type,.resource_id]|@tsv)' | column -t -s $'\t'
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false 
    RW.Core.Add To Report    Related Resources:   
    RW.Core.Add Pre To Report    ${resource_table.stdout}
 

*** Keywords ***
Suite Initialization
    ${AZ_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZ_RESOURCE_GROUP
    ...    type=string
    ...    description=The resource group to perform actions against.
    ...    pattern=\w*
    ${APP_GATEWAY_NAME}=    RW.Core.Import User Variable    APP_GATEWAY_NAME
    ...    type=string
    ...    description=The Azure Application Gateway to health check.
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
    Set Suite Variable    ${AZURE_RESOURCE_SUBSCRIPTION_ID}    ${AZURE_RESOURCE_SUBSCRIPTION_ID}
    Set Suite Variable    ${APP_GATEWAY_NAME}    ${APP_GATEWAY_NAME}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable
    ...    ${env}
    ...    {"APP_GATEWAY_NAME":"${APP_GATEWAY_NAME}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}", "AZURE_RESOURCE_SUBSCRIPTION_ID":"${AZURE_RESOURCE_SUBSCRIPTION_ID}"}