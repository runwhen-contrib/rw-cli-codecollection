*** Settings ***
Documentation       Performs a health check on Azure Application Gateways and the backend pools used by them, generating a report of issues and next steps.
Metadata            Author    jon-funk
Metadata            Display Name    Azure Application Gateway Fleet Health
Metadata            Supports    Azure    Application Gateway    Fleet    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check Application Gateway Fleet Health Status In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks the health status of a appgateway workload.
    [Tags]    
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=appgateway_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    IF    ${process.returncode} > 0
        RW.Core.Add Issue    title=Application Gateways In Resource Group `${AZ_RESOURCE_GROUP}` Failing Health Check
        ...    severity=2
        ...    next_steps=Tail the logs of the Application Gateways in resource group `${AZ_RESOURCE_GROUP}`\nReview resource usage metrics of Application Gateways in resource group `${AZ_RESOURCE_GROUP}`
        ...    expected=Application Gateways in resource group `${AZ_RESOURCE_GROUP}` should not be failing its health check
        ...    actual=Application Gateways in resource group `${AZ_RESOURCE_GROUP}` is failing its health check
        ...    reproduce_hint=Run appgateway_health.sh
        ...    details=${process.stdout}
    END
    RW.Core.Add Pre To Report    ${process.stdout}

Check Application Gateway Fleet Key Metrics In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Reviews key metrics for the application gateway and generates a report
    [Tags]    
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=appgateway_metrics.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${next_steps}=    RW.CLI.Run Cli    cmd=echo -e "${process.stdout}" | grep "Next Steps" -A 20 | tail -n +2
    IF    ${process.returncode} > 0
        RW.Core.Add Issue    title=Application Gateways In Resource Group `${AZ_RESOURCE_GROUP}` Failed Metric Check
        ...    severity=2
        ...    next_steps=${next_steps.stdout}
        ...    expected=Application Gateways in resource group `${AZ_RESOURCE_GROUP}` has no unusual metrics
        ...    actual=Application Gateways in resource group `${AZ_RESOURCE_GROUP}` metric check did not pass
        ...    reproduce_hint=Run appgateway_metrics.sh
        ...    details=${process.stdout}
    END
    RW.Core.Add Pre To Report    ${process.stdout}


*** Keywords ***
Suite Initialization
    ${AZ_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZ_RESOURCE_GROUP
    ...    type=string
    ...    description=The resource group to perform actions against.
    ...    pattern=\w*
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable
    ...    ${env}
    ...    {"AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}"}
