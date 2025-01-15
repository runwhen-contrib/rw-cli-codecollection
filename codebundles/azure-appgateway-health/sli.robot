*** Settings ***
Documentation       Queries the health of an Azure Application Gateway, returning 1 when it's healthy and 0 when it's unhealthy.
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
    [Documentation]    Fetch a list of issues that might affect the Application Gateway as reported from Azure. 
    [Tags]    aks    resource    health    service    azure
    ${resource_health}=    RW.CLI.Run Bash File
    ...    bash_file=app_gateway_resource_health.sh
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true

    ${resource_health_output}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/app_gateway_health.json | tr -d '\n'
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${resource_health_output_json}=    Evaluate    json.loads(r'''${resource_health_output.stdout}''')    json
    IF    len(@{resource_health_output_json}) > 0 
        ${appgw_resource_score}=    Evaluate    1 if "${resource_health_output_json["properties"]["title"]}" == "Available" else 0
    ELSE
        ${appgw_resource_score}=    Set Variable    0
    END
    Set Global Variable    ${appgw_resource_score}

Check Configuration Health of Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch the config of the AKS cluster in azure
    [Tags]    AKS    config
    ${config}=    RW.CLI.Run Bash File
    ...    bash_file=app_gateway_config_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/app_gateway_config_health.json | jq '{issues: [.issues[] | select(.severity < 4)]}'
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    ${appgw_config_score}=    Evaluate    1 if len(@{issue_list["issues"]}) == 0 else 0
    Set Global Variable    ${appgw_config_score}

Check Backend Pool Health for Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch the health of the application gateway backend pool members
    [Tags]    appservice    logs    tail
    ${config_health}=    RW.CLI.Run Bash File
    ...    bash_file=app_gateway_backend_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/backend_pool_members_health.json | jq '{issues: [.issues[] | select(.severity < 4)]}'
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    ${appgw_backend_score}=    Evaluate    1 if len(@{issue_list["issues"]}) == 0 else 0
    Set Global Variable    ${appgw_backend_score}


Generate AKS Cluster Health Score
    ${appgw_health_score}=      Evaluate  (${appgw_resource_score} + ${appgw_config_score} + ${appgw_backend_score}) / 3
    ${health_score}=      Convert to Number    ${appgw_health_score}  2
    RW.Core.Push Metric    ${health_score}
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
    ...    {"APP_GATEWAY_NAME":"${APP_GATEWAY_NAME}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}", "AZURE_RESOURCE_SUBSCRIPTION_ID":"${AZURE_RESOURCE_SUBSCRIPTION_ID}", "OUTPUT_DIR":"${OUTPUT_DIR}"}
