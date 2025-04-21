*** Settings ***
Documentation       Performs a health check on Azure Data factories
Metadata            Author    saurabh3460
Metadata            Display Name    Azure Data factories Health
Metadata            Supports    Azure    Data factories
Force Tags          Azure    Data Factory    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check for Resource Health Issues Affecting Data Factories in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Fetch health status for all Data Factories in the resource group
    [Tags]    datafactory    resourcehealth   access:read-only
    ${json_file}=    Set Variable    "datafactory_health.json"
    ${resource_health}=    RW.CLI.Run Bash File
    ...    bash_file=resource_health.sh
    ...    env=${env}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${resource_health.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${json_file}
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0 
        FOR    ${issue}    IN    @{issue_list}
            IF    "${issue["properties"]["title"]}" != "Available"
                RW.Core.Add Issue
                ...    severity=3
                ...    expected=Azure Data Factory resources should be available in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    actual=Azure Data Factory resources are unhealthy in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    title=Azure reports an `${issue["properties"]["title"]}` Issue for Data Factory
                ...    reproduce_hint=${resource_health.cmd}
                ...    details=${issue}
                ...    next_steps=Please escalate to the Azure service owner or check back later.
            END
        END
    ELSE
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Azure resources health should be enabled for Data Factories in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
        ...    actual=Azure resource health appears unavailable for Data Factories in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
        ...    title=Azure resource health is unavailable for Data Factories in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
        ...    reproduce_hint=${resource_health.cmd}
        ...    details=${issue_list}
        ...    next_steps=Please escalate to the Azure service owner to enable provider Microsoft.ResourceHealth.
    END
    RW.CLI.Run Cli
    ...    cmd=rm -f ${json_file}

Check for Frequent Pipeline Errors in Data Factories in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Check for frequently occurring errors in Data Factory pipelines
    [Tags]    datafactory    pipeline-errors    access:read-only
    ${json_file}=    Set Variable    "error_trend.json"
    ${error_check}=    RW.CLI.Run Bash File
    ...    bash_file=error_trend.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true

    TRY
        ${error_data}=    RW.CLI.Run Cli
        ...    cmd=cat ${json_file}
        ...    env=${env}
        ...    timeout_seconds=180
        ...    include_in_history=false
        ${error_trends}=    Evaluate    json.loads(r'''${error_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${error_trends}=    Create Dictionary    error_trends=[]
    END

    IF    len(${error_trends['error_trends']}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["Pipeline_Name", "Last_Seen", "Failure_Count", "RunId", "Resource_URL"], (.error_trends[] | [ .name, (.details | fromjson).LastSeen, (.details | fromjson).FailureCount, .run_id, .resource_url]) | @tsv' ${json_file} | column -t
        RW.Core.Add Pre To Report    Pipeline Error Trends Summary:\n==============================\n${formatted_results.stdout}

        FOR    ${error}    IN    @{error_trends['error_trends']}
            RW.Core.Add Issue
            ...    severity=${error['severity']}
            ...    expected=${error['expected']}
            ...    actual=${error['actual']}
            ...    title=${error['title']}
            ...    reproduce_hint=${error['reproduce_hint']}
            ...    details=${error['details']}
            ...    next_steps=${error['next_step']}
        END
    ELSE
        RW.Core.Add Pre To Report    "No pipeline errors found in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`"
    END

    RW.CLI.Run Cli
    ...    cmd=rm -f ${json_file}

*** Keywords ***
Suite Initialization
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    ${AZURE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure Subscription ID for the resource.  
    ...    pattern=\w*
    ...    default=""
    ${AZURE_SUBSCRIPTION_NAME}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_NAME
    ...    type=string
    ...    description=The Azure Subscription Name.  
    ...    pattern=\w*
    ...    default=""
    ${AZURE_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZURE_RESOURCE_GROUP
    ...    type=string
    ...    description=Azure resource group.
    ...    pattern=\w*
    Set Suite Variable    ${AZURE_SUBSCRIPTION_NAME}    ${AZURE_SUBSCRIPTION_NAME}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}", "AZURE_SUBSCRIPTION_NAME":"${AZURE_SUBSCRIPTION_NAME}"}