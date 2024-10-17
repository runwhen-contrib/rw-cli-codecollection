*** Settings ***
Documentation       Measures the number of exception stacktraces present in an application's logs over a time period.
Metadata            Author    jon-funk
Metadata            Display Name    Azure App Service Tail Application Logs
Metadata            Supports    Azure    App Service    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.K8sApplications

Suite Setup         Suite Initialization


*** Tasks ***
Tail AppService `${APPSERVICE}` Application Logs For Stacktraces
    [Documentation]    Tails logs and organizes output for measuring counts.
    [Tags]    resource    application    workload    logs    state    exceptions    errors
    ${cmd}=    Set Variable
    ...    az webapp log download --name ${APPSERVICE} --resource-group ${AZ_RESOURCE_GROUP} --log-file /tmp/az_app_service_log && unzip -qq -c /tmp/az_app_service_log
    IF    $EXCLUDE_PATTERN != ""
        ${cmd}=    Set Variable
        ...    ${cmd} | grep -Ev "${EXCLUDE_PATTERN}" || true
    END
    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${cmd}
    ...    env=${env}
    ${parsed_stacktraces}=    RW.K8sApplications.Dynamic Parse Stacktraces    ${logs.stdout}
    ...    parser_name=${STACKTRACE_PARSER}
    ...    parse_mode=${INPUT_MODE}
   ${count}=    Evaluate    len($parsed_stacktraces)
    RW.Core.Push Metric    ${count}


*** Keywords ***
Suite Initialization
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    ${AZ_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZ_RESOURCE_GROUP
    ...    type=string
    ...    description=The resource group to perform actions against.
    ...    pattern=\w*
    ${APPSERVICE}=    RW.Core.Import User Variable    APPSERVICE
    ...    type=string
    ...    description=The Azure AppService to triage.
    ...    pattern=\w*
    Set Suite Variable    ${APPSERVICE}    ${APPSERVICE}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable    ${INPUT_MODE}    ${INPUT_MODE}
    Set Suite Variable    ${STACKTRACE_PARSER}    ${STACKTRACE_PARSER}
    Set Suite Variable    ${EXCLUDE_PATTERN}    ${EXCLUDE_PATTERN}
    Set Suite Variable
    ...    ${env}
    ...    {"APPSERVICE":"${APPSERVICE}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}"}
