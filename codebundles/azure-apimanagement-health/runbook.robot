*** Settings ***
Documentation       Runs diagnostic checks against API Management Services and generates reports from key metrics.
Metadata            Author    jon-funk
Metadata            Display Name    Azure API Management Service Triage
Metadata            Supports    Azure    API    Management    Service    Triage    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check API Service `${API}` Key Metrics In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks key metrics of API service for issues.
    [Tags]    API Service       Azure    Metrics    Health
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=api_metrics.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${next_steps}=    RW.CLI.Run Cli    cmd=echo -e "${process.stdout}" | grep "Next Steps" -A 20 | tail -n +2
    IF    ${process.returncode} > 0
        RW.Core.Add Issue    title=API Management Service `${API}` In Resource Group `${AZ_RESOURCE_GROUP}` Failed Metric Check
        ...    severity=2
        ...    next_steps=${next_steps.stdout}
        ...    expected=API Management Service`${API}` in resource group `${AZ_RESOURCE_GROUP}` has no unusual metrics
        ...    actual=API Management Service`${API}` in resource group `${AZ_RESOURCE_GROUP}` metric check did not pass
        ...    reproduce_hint=Run api_metrics.sh
        ...    details=${process.stdout}
    END
    RW.Core.Add Pre To Report    ${process.stdout}


Fetch API Management Service`${API}` Config In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch the config of the scaled set in azure
    [Tags]        Scaled Set    config   
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=api_activities.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    IF    ${process.returncode} > 0
        RW.Core.Add Issue    title=Azure Resource `${API}` In Resource Group `${AZ_RESOURCE_GROUP}` Has Errors In Activities
        ...    severity=3
        ...    next_steps=Review the report details produced by the configuration scan
        ...    expected=Azure Resource `${API}` in resource group `${AZ_RESOURCE_GROUP}` has no misconfiguration(s)
        ...    actual=Azure Resource `${API}` in resource group `${AZ_RESOURCE_GROUP}` has misconfiguration(s)
        ...    reproduce_hint=Run config.sh
        ...    details=${process.stdout}
    END
    RW.Core.Add Pre To Report    ${process.stdout}

Scan API Management Service`${API}` Activities In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Gets the events for the scaled set and checks for errors
    [Tags]    VM    Scaled Set    monitor    events    errors
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=api_activities.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${next_steps}=    RW.CLI.Run Cli    cmd=echo -e "${process.stdout}" | grep "Next Steps" -A 20 | tail -n +2
    IF    ${process.returncode} > 0
        RW.Core.Add Issue    title=Azure Resource `${API}` In Resource Group `${AZ_RESOURCE_GROUP}` Has Errors In Activities
        ...    severity=3
        ...    next_steps=${next_steps.stdout}
        ...    expected=Azure Resource `${API}` in resource group `${AZ_RESOURCE_GROUP}` has no errors or criticals in activity logs
        ...    actual=Azure Resource `${API}` in resource group `${AZ_RESOURCE_GROUP}` has errors or critical events in activity logs
        ...    reproduce_hint=Run activities.sh
        ...    details=${process.stdout}
    END
    RW.Core.Add Pre To Report    ${process.stdout}



*** Keywords ***
Suite Initialization
    ${AZ_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZ_RESOURCE_GROUP
    ...    type=string
    ...    description=The resource group to perform actions against.
    ...    pattern=\w*
    ${API}=    RW.Core.Import User Variable    API
    ...    type=string
    ...    description=The Azure Virtual Machine Scaled Set to triage.
    ...    pattern=\w*
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    Set Suite Variable    ${API}    ${API}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable
    ...    ${env}
    ...    {"API":"${API}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}"}
