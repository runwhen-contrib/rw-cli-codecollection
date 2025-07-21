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
    ${sb_health_output}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_health.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${sb_health_output_list}=    Evaluate    json.loads(r'''${sb_health_output.stdout}''')    json
    IF    len(@{sb_health_output_list}) > 0 
        ${sb_resource_score}=    Evaluate    1 if "${sb_health_output_list["properties"]["title"]}" == "Available" else 0
    ELSE
        ${sb_resource_score}=    Set Variable    0
    END
    Set Global Variable    ${sb_resource_score}

Check Basic Connectivity for Service Bus `${SB_NAMESPACE_NAME}`
    [Documentation]    Quick connectivity test to detect network issues
    [Tags]    azure    servicebus    connectivity    access:read-only
    ${connectivity}=    RW.CLI.Run Bash File
    ...    bash_file=service_bus_connectivity_test.sh
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    ${connectivity_data}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_connectivity.json
    ...    env=${env}
    ...    timeout_seconds=10
    ...    include_in_history=false
    ${connectivity_json}=    Evaluate    json.loads(r'''${connectivity_data.stdout}''')    json
    
    # Score based on connectivity tests
    ${connectivity_score}=    Set Variable    1
    IF    "${connectivity_json['tests']['amqp_port_connectivity']}" == "failure"
        ${connectivity_score}=    Evaluate    ${connectivity_score} - 0.5
    END
    IF    "${connectivity_json['tests']['https_port_connectivity']}" == "failure"
        ${connectivity_score}=    Evaluate    ${connectivity_score} - 0.5
    END
    IF    "${connectivity_json['tests']['dns_resolution']}" == "false"
        ${connectivity_score}=    Evaluate    ${connectivity_score} - 0.5
    END
    Set Global Variable    ${connectivity_score}

Check Critical Metrics for Service Bus `${SB_NAMESPACE_NAME}`
    [Documentation]    Quick check of critical metrics that indicate immediate issues
    [Tags]    azure    servicebus    metrics    access:read-only
    ${metrics}=    RW.CLI.Run Bash File
    ...    bash_file=service_bus_metrics.sh
    ...    env=${env}
    ...    timeout_seconds=45
    ...    include_in_history=false
    ${metrics_data}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_metrics_issues.json
    ...    env=${env}
    ...    timeout_seconds=10
    ...    include_in_history=false
    ${metrics_json}=    Evaluate    json.loads(r'''${metrics_data.stdout}''')    json
    
    # Score based on critical issues
    ${metrics_score}=    Set Variable    1
    IF    len(@{metrics_json["issues"]}) > 0
        FOR    ${issue}    IN    @{metrics_json["issues"]}
            IF    ${issue["severity"]} == 1
                ${metrics_score}=    Evaluate    ${metrics_score} - 0.5
            ELSE IF    ${issue["severity"]} == 2
                ${metrics_score}=    Evaluate    ${metrics_score} - 0.25
            END
        END
    END
    Set Global Variable    ${metrics_score}

Generate Enhanced Service Bus Health Score
    ${enhanced_health_score}=    Evaluate    (${sb_resource_score} + ${connectivity_score} + ${metrics_score}) / 3
    ${health_score}=    Convert to Number    ${enhanced_health_score}    2
    RW.Core.Push Metric    ${health_score}

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
    # Set Azure subscription context
    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
    ...    include_in_history=false
