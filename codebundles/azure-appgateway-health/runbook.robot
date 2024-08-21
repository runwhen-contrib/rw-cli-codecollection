*** Settings ***
Documentation       Performs a health check on Azure Application Gateways and the backend pools used by them, generating a report of issues and next steps.
Metadata            Author    jon-funk
Metadata            Display Name    Azure Application Gateway Health
Metadata            Supports    Azure    Application Gateway    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check Application Gateway `${APPGATEWAY}` Health Status In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks the health status of a appgateway workload.
    [Tags]    
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=appgateway_health.sh
    ...    env=${env}
    ...    secret__AZ_USERNAME=${AZ_USERNAME}
    ...    secret__AZ_SECRET_VALUE=${AZ_SECRET_VALUE}
    ...    secret__AZ_TENANT=${AZ_TENANT}
    ...    secret__AZ_SUBSCRIPTION=${AZ_SUBSCRIPTION}
    ...    timeout_seconds=180
    ...    include_in_history=false
    IF    ${process.returncode} > 0
        RW.Core.Add Issue    title=Application Gateway `${APPGATEWAY}` In Resource Group `${AZ_RESOURCE_GROUP}` Failing Health Check
        ...    severity=2
        ...    next_steps=Tail the logs of the Application Gateway `${APPGATEWAY}` in resource group `${AZ_RESOURCE_GROUP}`\nReview resource usage metrics of Application Gateway `${APPGATEWAY}` in resource group `${AZ_RESOURCE_GROUP}`
        ...    expected=Application Gateway `${APPGATEWAY}` in resource group `${AZ_RESOURCE_GROUP}` should not be failing its health check
        ...    actual=Application Gateway `${APPGATEWAY}` in resource group `${AZ_RESOURCE_GROUP}` is failing its health check
        ...    reproduce_hint=Run appgateway_health.sh
        ...    details=${process.stdout}
    END
    RW.Core.Add Pre To Report    ${process.stdout}

Check AppService `${APPGATEWAY}` Key Metrics In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Reviews key metrics for the application gateway and generates a report
    [Tags]    
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=appgateway_metrics.sh
    ...    env=${env}
    ...    secret__AZ_USERNAME=${AZ_USERNAME}
    ...    secret__AZ_SECRET_VALUE=${AZ_SECRET_VALUE}
    ...    secret__AZ_TENANT=${AZ_TENANT}
    ...    secret__AZ_SUBSCRIPTION=${AZ_SUBSCRIPTION}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${next_steps}=    RW.CLI.Run Cli    cmd=echo -e "${process.stdout}" | grep "Next Steps" -A 20 | tail -n +2
    IF    ${process.returncode} > 0
        RW.Core.Add Issue    title=Application Gateway `${APPGATEWAY}` In Resource Group `${AZ_RESOURCE_GROUP}` Failed Metric Check
        ...    severity=2
        ...    next_steps=${next_steps.stdout}
        ...    expected=Application Gateway `${APPGATEWAY}` in resource group `${AZ_RESOURCE_GROUP}` has no unusual metrics
        ...    actual=Application Gateway `${APPGATEWAY}` in resource group `${AZ_RESOURCE_GROUP}` metric check did not pass
        ...    reproduce_hint=Run appgateway_metrics.sh
        ...    details=${process.stdout}
    END
    RW.Core.Add Pre To Report    ${process.stdout}

Fetch Application Gateway `${APPGATEWAY}` Config In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch logs of appgateway workload
    [Tags]    appgateway    logs    tail
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=appgateway_config.sh
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
    ${APPGATEWAY}=    RW.Core.Import User Variable    APPGATEWAY
    ...    type=string
    ...    description=The Azure Application Gateway to health check.
    ...    pattern=\w*

    Set Suite Variable    ${APPGATEWAY}    ${APPGATEWAY}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable    ${AZ_USERNAME}    ${AZ_USERNAME}
    Set Suite Variable    ${AZ_SECRET_VALUE}    ${AZ_SECRET_VALUE}
    Set Suite Variable    ${AZ_TENANT}    ${AZ_TENANT}
    Set Suite Variable    ${AZ_SUBSCRIPTION}    ${AZ_SUBSCRIPTION}
    Set Suite Variable
    ...    ${env}
    ...    {"APPGATEWAY":"${APPGATEWAY}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}"}
