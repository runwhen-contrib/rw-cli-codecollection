*** Settings ***
Documentation       Performs a health check on Azure Service Bus instances and the components using them, generating a report of issues and next steps.
Metadata            Author    stewartshea
Metadata            Display Name    Azure Service Bus Health
Metadata            Supports    Azure    ServiceBus 

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check for Resource Health Issues Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch a list of issues that might affect the service bus instance
    [Tags]    azure    servicebus    resourcehealth   access:read-only
    ${resource_health}=    RW.CLI.Run Bash File
    ...    bash_file=service_bus_resource_health.sh
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
    ...    cmd=cat service_bus_health.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0 
        IF    "${issue_list["properties"]["title"]}" != "Available"
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=Azure resources should be available for Service Bus `${SB_NAMESPACE_NAME}` in `${AZ_RESOURCE_GROUP}`
            ...    actual=Azure resources are unhealthy for Service Bus `${SB_NAMESPACE_NAME}` in `${AZ_RESOURCE_GROUP}`
            ...    title=Azure reports an `${issue_list["properties"]["title"]}` Issue for Service Bus `${SB_NAMESPACE_NAME}` in `${AZ_RESOURCE_GROUP}`
            ...    reproduce_hint=${resource_health.cmd}
            ...    details=${issue_list}
            ...    next_steps=Please escalate to the Azure service owner or check back later.
        END
    ELSE
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Azure resources health should be enabled for Service Bus `${SB_NAMESPACE_NAME}` in `${AZ_RESOURCE_GROUP}`
        ...    actual=Azure resource health appears unavailable for Service Bus `${SB_NAMESPACE_NAME}` in `${AZ_RESOURCE_GROUP}`
        ...    title=Azure resource health is unavailable for Service Bus `${SB_NAMESPACE_NAME}` in `${AZ_RESOURCE_GROUP}`
        ...    reproduce_hint=${resource_health.cmd}
        ...    details=${issue_list}
        ...    next_steps=Please escalate to the Azure service owner to enable provider Microsoft.ResourceHealth.
    END

Check Configuration Health for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch the details and health of the service bus configuration
    [Tags]    servicebus    logs    config    access:read-only
    ${config_health}=    RW.CLI.Run Bash File
    ...    bash_file=service_bus_config_health.sh
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
    ${report}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_namespace.txt
    RW.Core.Add Pre To Report    ${report.stdout} 
      
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_config_health.json
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
            ...    expected=Service Bus `${SB_NAMESPACE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has a healthy configuration
            ...    actual=Service Bus `${SB_NAMESPACE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has configuration recommendations
            ...    reproduce_hint=${config_health.cmd}
            ...    details=${item["details"]}        
        END
    END

*** Keywords ***
Suite Initialization
    ${AZ_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZ_RESOURCE_GROUP
    ...    type=string
    ...    description=The resource group to perform actions against.
    ...    pattern=\w*
    ${SB_NAMESPACE_NAME}=    RW.Core.Import User Variable    SB_NAMESPACE_NAME
    ...    type=string
    ...    description=The Azure Service Bus to health check. 
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
    Set Suite Variable    ${SB_NAMESPACE_NAME}    ${SB_NAMESPACE_NAME}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable
    ...    ${env}
    ...    {"SB_NAMESPACE_NAME":"${SB_NAMESPACE_NAME}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}", "AZURE_RESOURCE_SUBSCRIPTION_ID":"${AZURE_RESOURCE_SUBSCRIPTION_ID}"}