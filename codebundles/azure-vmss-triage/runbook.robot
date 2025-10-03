*** Settings ***
Documentation       Runs diagnostic checks against virtual machine scaled sets and generates reports from key metrics.
Metadata            Author    jon-funk
Metadata            Display Name    Azure VM Scale Set Triage
Metadata            Supports    Azure    Virtual Machine    Scale Set    Triage    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library    String

Suite Setup         Suite Initialization


*** Tasks ***
Check Scale Set `${VMSCALESET}` Key Metrics In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks key metrics of VM Scale Set for issues.
    [Tags]    Scale Set    VM    Azure    Metrics    Health
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=vmss_metrics.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${next_steps}=    RW.CLI.Run Cli    cmd=echo -e "${process.stdout}" | grep "Next Steps" -A 20 | tail -n +2
    IF    ${process.returncode} > 0
        ${issue_timestamp}=    RW.Core.Get Issue Timestamp

        RW.Core.Add Issue    title=VM Scale Set `${VMSCALESET}` In Resource Group `${AZ_RESOURCE_GROUP}` Failed Metric Check
        ...    severity=2
        ...    next_steps=${next_steps.stdout}
        ...    expected=VM Scale Set `${VMSCALESET}` in resource group `${AZ_RESOURCE_GROUP}` has no unusual metrics
        ...    actual=VM Scale Set `${VMSCALESET}` in resource group `${AZ_RESOURCE_GROUP}` metric check did not pass
        ...    reproduce_hint=Run vmss_metrics.sh
        ...    details=${process.stdout}
        ...    observed_at=${issue_timestamp}
    END
    RW.Core.Add Pre To Report    ${process.stdout}

Fetch VM Scale Set `${VMSCALESET}` Config In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch the config of the scaled set in azure
    [Tags]    VM    Scale Set    logs    tail
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=vmss_config.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${process.stdout}

Fetch Activities for VM Scale Set `${VMSCALESET}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Gets the events for the scaled set and checks for errors
    [Tags]    VM    Scale Set    monitor    events    errors
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=vmss_activities.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    RW.Core.Add Pre To Report    ${process.stdout}

    ${issues}=    RW.CLI.Run Cli    cmd=cat ${OUTPUT DIR}/issues.json 
    Log    ${issues.stdout}
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            ${issue_timestamp}=    RW.Core.Get Issue Timestamp

            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=VM Scale Set `${VMSCALESET}` in resource group `${AZ_RESOURCE_GROUP}` has no Warning/Error/Critical activities
            ...    actual=VM Scale Set `${VMSCALESET}` in resource group `${AZ_RESOURCE_GROUP}` has Warning/Error/Critical activities
            ...    reproduce_hint=Run vmss_metrics.sh
            ...    details=${item["details"]}
            ...    observed_at=${issue_timestamp}
        END
    END


*** Keywords ***
Suite Initialization
    ${AZ_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZ_RESOURCE_GROUP
    ...    type=string
    ...    description=The resource group to perform actions against.
    ...    pattern=\w*
    ${VMSCALESET}=    RW.Core.Import User Variable    VMSCALESET
    ...    type=string
    ...    description=The Azure Virtual Machine Scale Set to triage.
    ...    pattern=\w*
    ${TIME_PERIOD_MINUTES}=    RW.Core.Import User Variable    TIME_PERIOD_MINUTES
    ...    type=string
    ...    description=The time period, in minutes, to look back for activites/events. 
    ...    pattern=\w*
    ...    default=60
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
    Set Suite Variable    ${VMSCALESET}    ${VMSCALESET}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable    ${TIME_PERIOD_MINUTES}    ${TIME_PERIOD_MINUTES}
    Set Suite Variable
    ...    ${env}
    ...    {"VMSCALESET":"${VMSCALESET}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}", "TIME_PERIOD_MINUTES": "${TIME_PERIOD_MINUTES}", "AZURE_RESOURCE_SUBSCRIPTION_ID":"${AZURE_RESOURCE_SUBSCRIPTION_ID}"}
    # Set Azure subscription context
    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
            ...    observed_at=${issue_timestamp}
    ...    include_in_history=false
