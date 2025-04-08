*** Settings ***
Documentation       Runs diagnostic checks to check the health of APIM instances
Metadata            Author    stewartshea
Metadata            Display Name    Azure APIM Health
Metadata            Supports    Azure    APIM    Service    Triage    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Gather APIM Resource Information for APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Collect fundamental details about the Azure subscription, resource group,
    ...               and the APIM instance before proceeding with troubleshooting.
    [Tags]    apim    config    access:read-only
    ${apim_config}=    RW.CLI.Run Bash File
    ...    bash_file=gather_apim_resource_information.sh
    ...    env=${env}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${apim_config.stdout}
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat apim_config_issues.json
    ...    env=${env}
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0 
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue
            ...    severity=${item["severity"]}
            ...    expected=APIM config should not have recommendations
            ...    actual=APIM config ahs recommendations
            ...    title=${item["title"]}
            ...    reproduce_hint=${apim_config.cmd}
            ...    details=${item["details"]}
            ...    next_steps=${item["next_steps"]}
        END
    END

Check for Resource Health Issues Affecting APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch Resource Health status and evaluate any reported issues for the APIM instance.
    [Tags]    apim    resourcehealth    access:read-only

    ${resource_health}=    RW.CLI.Run Bash File
    ...    bash_file=apim_resource_health.sh
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true

    RW.Core.Add Pre To Report    ${resource_health.stdout}

    IF    "${resource_health.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Warnings/Errors running APIM Resource Health script
        ...    severity=3
        ...    next_steps=Review debug logs in the Robot report
        ...    expected=No stderr output
        ...    actual=stderr encountered
        ...    reproduce_hint=${resource_health.cmd}
        ...    details=${resource_health.stderr}
    END

    # 4) Read the JSON output from apim_resource_health.json
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat apim_resource_health.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json

    IF    len(${issue_list}) > 0
        # We assume the returned JSON is an object, not an array. Adjust accordingly if it's different.
        ${status_title}=    Set Variable    ${issue_list["properties"]["title"]}

        IF    "${status_title}" != "Available"
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=APIM should be marked "Available" in Resource Health
            ...    actual=Azure resources are unhealthy for APIM `${APIM_NAME}` in `${AZ_RESOURCE_GROUP}`
            ...    title=Azure reports a `${status_title}` issue for APIM `${APIM_NAME}` in `${AZ_RESOURCE_GROUP}`
            ...    reproduce_hint=${resource_health.cmd}
            ...    details=${issue_list}
            ...    next_steps=Consult Azure Resource Health documentation or escalate to service owner.
        END
    ELSE
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=APIM Resource Health should return a valid status
        ...    actual=No valid data returned or JSON was empty
        ...    title=APIM Resource Health is unavailable for `${APIM_NAME}` in `${AZ_RESOURCE_GROUP}`
        ...    reproduce_hint=${resource_health.cmd}
        ...    details=${issue_list}
        ...    next_steps=Enable Resource Health or check provider registration for Microsoft.ResourceHealth
    END

*** Keywords ***
Suite Initialization
    ${AZ_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZ_RESOURCE_GROUP
    ...    type=string
    ...    description=The resource group to perform actions against.
    ...    pattern=\w*
    ${APIM_NAME}=    RW.Core.Import User Variable    APIM_NAME
    ...    type=string
    ...    description=The APIM Instance Name
    ...    pattern=\w*
    ${TIME_PERIOD_MINUTES}=    RW.Core.Import User Variable    TIME_PERIOD_MINUTES
    ...    type=string
    ...    description=The time period, in minutes, to look back for activites/events. 
    ...    pattern=\w*
    ...    default=60
    ${AZURE_RESOURCE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_RESOURCE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure Subscription ID for the resource.  
    ...    pattern=\w*
    ...    default=""
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    Set Suite Variable    ${AZURE_RESOURCE_SUBSCRIPTION_ID}    ${AZURE_RESOURCE_SUBSCRIPTION_ID}
    Set Suite Variable    ${APIM_NAME}    ${APIM_NAME}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable    ${TIME_PERIOD_MINUTES}    ${TIME_PERIOD_MINUTES}
    Set Suite Variable
    ...    ${env}
    ...    {"APIM_NAME":"${APIM_NAME}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}", "TIME_PERIOD_MINUTES":"${TIME_PERIOD_MINUTES}", "AZURE_RESOURCE_SUBSCRIPTION_ID":"${AZURE_RESOURCE_SUBSCRIPTION_ID}"}
