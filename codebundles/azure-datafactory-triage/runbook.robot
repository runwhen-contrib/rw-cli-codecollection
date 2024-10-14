*** Settings ***
Documentation       Runs diagnostic checks against an ADF.
Metadata            Author    jon-funk
Metadata            Display Name    Azure ADF Triage
Metadata            Supports    Azure    ADF    Service    Triage    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Fetch ADF `${ADF}` Config In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch the config of the ADF in azure
    [Tags]        ADF    config   
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=adf_config.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${process.stdout}

Scan ADF `${ADF}` Activities In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Gets the activities of the ADF cluster.
    [Tags]    ADF      monitor    events    errors
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=adf_activities.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${process.stdout}

Health Check `${ADF}` Key ADF Metrics Configuration In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    performs a validation of the config of the ADF cluster.
    [Tags]    ADF     monitor    events    errors
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=adf_metrics.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${next_steps}=    RW.CLI.Run Cli    cmd=echo -e "${process.stdout}" | grep "Next Steps" -A 20 | tail -n +2
    IF    ${process.returncode} > 0
        RW.Core.Add Issue    title=ADF `${ADF}` In Resource Group `${AZ_RESOURCE_GROUP}` Failed Metric Check
        ...    severity=2
        ...    next_steps=${next_steps.stdout}
        ...    expected=ADF `${ADF}` in resource group `${AZ_RESOURCE_GROUP}` has no unusual metrics
        ...    actual=ADF `${ADF}` in resource group `${AZ_RESOURCE_GROUP}` metric check did not pass
        ...    reproduce_hint=Run adf_metrics.sh
        ...    details=${process.stdout}
    END
    RW.Core.Add Pre To Report    ${process.stdout}


*** Keywords ***
Suite Initialization
    ${AZ_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZ_RESOURCE_GROUP
    ...    type=string
    ...    description=The resource group to perform actions against.
    ...    pattern=\w*
    ${ADF}=    RW.Core.Import User Variable    ADF
    ...    type=string
    ...    description=The Azure ADF cluster to triage.
    ...    pattern=\w*
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    Set Suite Variable    ${ADF}    ${ADF}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable
    ...    ${env}
    ...    {"ADF":"${ADF}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}"}
