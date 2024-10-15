*** Settings ***
Documentation       Runs diagnostic checks against virtual machine scaled sets and generates reports from key metrics.
Metadata            Author    jon-funk
Metadata            Display Name    Azure VM Scaled Set Triage
Metadata            Supports    Azure    Virtual Machine    Scaled Set    Triage    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check Scaled Set `${VMSCALEDSET}` Key Metrics In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks key metrics of VM Scaled Set for issues.
    [Tags]    Scaled Set    VM    Azure    Metrics    Health
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=vmss_metrics.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${next_steps}=    RW.CLI.Run Cli    cmd=echo -e "${process.stdout}" | grep "Next Steps" -A 20 | tail -n +2
    IF    ${process.returncode} > 0
        RW.Core.Add Issue    title=VM Scaled Set `${VMSCALEDSET}` In Resource Group `${AZ_RESOURCE_GROUP}` Failed Metric Check
        ...    severity=2
        ...    next_steps=${next_steps.stdout}
        ...    expected=VM Scaled Set `${VMSCALEDSET}` in resource group `${AZ_RESOURCE_GROUP}` has no unusual metrics
        ...    actual=VM Scaled Set `${VMSCALEDSET}` in resource group `${AZ_RESOURCE_GROUP}` metric check did not pass
        ...    reproduce_hint=Run vmss_metrics.sh
        ...    details=${process.stdout}
    END
    RW.Core.Add Pre To Report    ${process.stdout}


Fetch VM Scaled Set `${VMSCALEDSET}` Config In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch the config of the scaled set in azure
    [Tags]    VM    Scaled Set    logs    tail
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=vmss_activities.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    IF    ${process.returncode} > 0
        RW.Core.Add Issue    title=Azure Resource `${VMSCALEDSET}` In Resource Group `${AZ_RESOURCE_GROUP}` Has Errors In Activities
        ...    severity=3
        ...    next_steps=Review the report details produced by the configuration scan
        ...    expected=Azure Resource `${VMSCALEDSET}` in resource group `${AZ_RESOURCE_GROUP}` has no misconfiguration(s)
        ...    actual=Azure Resource `${VMSCALEDSET}` in resource group `${AZ_RESOURCE_GROUP}` has misconfiguration(s)
        ...    reproduce_hint=Run config.sh
        ...    details=${process.stdout}
    END
    RW.Core.Add Pre To Report    ${process.stdout}

Scan VM Scaled Set `${VMSCALEDSET}` Activities In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Gets the events for the scaled set and checks for errors
    [Tags]    VM    Scaled Set    monitor    events    errors
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=vmss_activities.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${process.stdout}



*** Keywords ***
Suite Initialization
    ${AZ_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZ_RESOURCE_GROUP
    ...    type=string
    ...    description=The resource group to perform actions against.
    ...    pattern=\w*
    ${VMSCALEDSET}=    RW.Core.Import User Variable    VMSCALEDSET
    ...    type=string
    ...    description=The Azure Virtual Machine Scaled Set to triage.
    ...    pattern=\w*
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    Set Suite Variable    ${VMSCALEDSET}    ${VMSCALEDSET}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable
    ...    ${env}
    ...    {"VMSCALEDSET":"${VMSCALEDSET}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}"}
