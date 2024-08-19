*** Settings ***
Documentation       Triages an Azure App Service and its workloads, checking its status and logs and verifying key metrics.
Metadata            Author    jon-funk
Metadata            Display Name    Azure App Service Triage
Metadata            Supports    Azure    App Service    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check AppService `${APPSERVICE}` Health Status In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks the health status of a appservice workload.
    [Tags]    
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_health.sh
    ...    env=${env}
    ...    secret__AZ_USERNAME=${AZ_USERNAME}
    ...    secret__AZ_SECRET_VALUE=${AZ_SECRET_VALUE}
    ...    secret__AZ_TENANT=${AZ_TENANT}
    ...    secret__AZ_SUBSCRIPTION=${AZ_SUBSCRIPTION}
    ...    timeout_seconds=180
    ...    include_in_history=false
    IF    ${process.returncode} > 0
        RW.Core.Add Issue    title=App Service `${APPSERVICE}` In Resource Group `${AZ_RESOURCE_GROUP}` Failing Health Check
        ...    severity=2
        ...    next_steps=Tail the logs of the App Service `${APPSERVICE}` in resource group `${AZ_RESOURCE_GROUP}`\nReview resource usage metrics of App Service `${APPSERVICE}` in resource group `${AZ_RESOURCE_GROUP}`
        ...    expected=App Service `${APPSERVICE}` in resource group `${AZ_RESOURCE_GROUP}` should not be failing its health check
        ...    actual=App Service `${APPSERVICE}` in resource group `${AZ_RESOURCE_GROUP}` is failing its health check
        ...    reproduce_hint=Run appservice_health.sh
        ...    details=${process.stdout}
    END
    RW.Core.Add Pre To Report    ${process.stdout}

Check AppService `${APPSERVICE}` Key Metrics In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Reviews key metrics for the app service and generates a report
    [Tags]    
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_metrics.sh
    ...    env=${env}
    ...    secret__AZ_USERNAME=${AZ_USERNAME}
    ...    secret__AZ_SECRET_VALUE=${AZ_SECRET_VALUE}
    ...    secret__AZ_TENANT=${AZ_TENANT}
    ...    secret__AZ_SUBSCRIPTION=${AZ_SUBSCRIPTION}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${next_steps}=    RW.CLI.Run Cli    cmd=echo -e "${process.stdout}" | grep "Next Steps" -A 20 | tail -n +2
    IF    ${process.returncode} > 0
        RW.Core.Add Issue    title=App Service `${APPSERVICE}` In Resource Group `${AZ_RESOURCE_GROUP}` Failed Metric Check
        ...    severity=2
        ...    next_steps=${next_steps.stdout}
        ...    expected=App Service `${APPSERVICE}` in resource group `${AZ_RESOURCE_GROUP}` has no unusual metrics
        ...    actual=App Service `${APPSERVICE}` in resource group `${AZ_RESOURCE_GROUP}` metric check did not pass
        ...    reproduce_hint=Run appservice_metrics.sh
        ...    details=${process.stdout}
    END
    RW.Core.Add Pre To Report    ${process.stdout}

Get AppService `${APPSERVICE}` Logs In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch logs of appservice workload
    [Tags]    appservice    logs    tail
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_logs.sh
    ...    env=${env}
    ...    secret__AZ_USERNAME=${AZ_USERNAME}
    ...    secret__AZ_SECRET_VALUE=${AZ_SECRET_VALUE}
    ...    secret__AZ_TENANT=${AZ_TENANT}
    ...    secret__AZ_SUBSCRIPTION=${AZ_SUBSCRIPTION}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${process.stdout}

Fetch App Service `${APPSERVICE}` Config In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch logs of appservice workload
    [Tags]    appservice    logs    tail
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_config.sh
    ...    env=${env}
    ...    secret__AZ_USERNAME=${AZ_USERNAME}
    ...    secret__AZ_SECRET_VALUE=${AZ_SECRET_VALUE}
    ...    secret__AZ_TENANT=${AZ_TENANT}
    ...    secret__AZ_SUBSCRIPTION=${AZ_SUBSCRIPTION}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${process.stdout}

Scan AppService `${APPSERVICE}` Event Errors In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Gets the events of appservice and checks for errors
    [Tags]    appservice    monitor    events    errors
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_activities.sh
    ...    env=${env}
    ...    secret__AZ_USERNAME=${AZ_USERNAME}
    ...    secret__AZ_SECRET_VALUE=${AZ_SECRET_VALUE}
    ...    secret__AZ_TENANT=${AZ_TENANT}
    ...    secret__AZ_SUBSCRIPTION=${AZ_SUBSCRIPTION}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${process.stdout}

*** Keywords ***
Suite Initialization
    ${AZ_USERNAME}=    RW.Core.Import Secret
    ...    AZ_USERNAME
    ...    type=string
    ...    description=The azure service principal client ID on the app registration.
    ...    pattern=\w*
    ${AZ_SECRET_VALUE}=    RW.Core.Import Secret
    ...    AZ_SECRET_VALUE
    ...    type=string
    ...    description=The service principal secret value on the associated credential for the app registration.
    ...    pattern=\w*
    ${AZ_TENANT}=    RW.Core.Import Secret
    ...    AZ_TENANT
    ...    type=string
    ...    description=The azure tenant ID used by the service principal to authenticate with azure.
    ...    pattern=\w*
    ${AZ_SUBSCRIPTION}=    RW.Core.Import Secret
    ...    AZ_SUBSCRIPTION
    ...    type=string
    ...    description=The azure tenant ID used by the service principal to authenticate with azure.
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
    Set Suite Variable    ${AZ_USERNAME}    ${AZ_USERNAME}
    Set Suite Variable    ${AZ_SECRET_VALUE}    ${AZ_SECRET_VALUE}
    Set Suite Variable    ${AZ_TENANT}    ${AZ_TENANT}
    Set Suite Variable    ${AZ_SUBSCRIPTION}    ${AZ_SUBSCRIPTION}
    Set Suite Variable
    ...    ${env}
    ...    {"APPSERVICE":"${APPSERVICE}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}"}
