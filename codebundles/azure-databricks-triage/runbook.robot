*** Settings ***
Documentation       Runs diagnostic checks against an Azure Databricks workspace.
Metadata            Author    jon-funk
Metadata            Display Name    Azure Azure Databricks workspace Triage
Metadata            Supports    Azure    Azure Databricks workspace    Service    Triage    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Fetch ADB `${ADB}` Config In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch the config of the ADB in azure
    [Tags]        ADB    config   
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=adf_config.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${process.stdout}

Scan ADB `${ADB}` Activities In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Gets the activities of the ADB cluster.
    [Tags]    ADB      monitor    events    errors
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=adf_activities.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${next_steps}=    RW.CLI.Run Cli    cmd=echo -e "${process.stdout}" | grep "Next Steps" -A 20 | tail -n +2
    IF    ${process.returncode} > 0
        RW.Core.Add Issue    title=Azure Resource `${ADB}` In Resource Group `${AZ_RESOURCE_GROUP}` Has Errors In Activities
        ...    severity=3
        ...    next_steps=${next_steps.stdout}
        ...    expected=Azure Resource `${ADB}` in resource group `${AZ_RESOURCE_GROUP}` has no errors or criticals in activity logs
        ...    actual=Azure Resource `${ADB}` in resource group `${AZ_RESOURCE_GROUP}` has errors or critical events in activity logs
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
    ${ADB}=    RW.Core.Import User Variable    ADB
    ...    type=string
    ...    description=The Azure ADB cluster to triage.
    ...    pattern=\w*
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    Set Suite Variable    ${ADB}    ${ADB}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable
    ...    ${env}
    ...    {"ADB":"${ADB}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}"}
