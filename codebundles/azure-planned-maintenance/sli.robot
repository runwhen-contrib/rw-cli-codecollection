*** Settings ***
Documentation       Check Azure planned maintenance events, service issue events, and impacted resources
Metadata            Author    saurabh3460
Metadata            Display Name    Azure    Planned Maintenance
Metadata            Supports    Azure    Planned Maintenance
Force Tags          Azure    Planned Maintenance

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform


Suite Setup         Suite Initialization
*** Tasks ***
Count Azure Planned Maintenance Events
    [Documentation]    Count the number of Azure planned maintenance events for the subscription
    [Tags]    SLI    Azure    Maintenance    access:read-only
    # Run the script to fetch maintenance events
    ${maintenance_cmd}=    RW.CLI.Run Bash File
    ...    bash_file=maintenance-event.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false

    # Read the output file
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat maintenance_events.json

    TRY
        ${event_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        ${event_list}=    Create List
    END

    ${maintenance_event_count}=    Get Length    ${event_list}
    Set Global Variable    ${maintenance_event_count}

    # Optional: Set a score variable (1 if no events, 0 otherwise)
    ${maintenance_event_score}=    Evaluate    1 if int(${maintenance_event_count}) == 0 else 0
    Set Global Variable    ${maintenance_event_score}

Count Azure Service Issue Events
    [Documentation]    Count the number of Azure service issue events for the subscription
    [Tags]    SLI    Azure    ServiceIssue    access:read-only
    # Run the script to fetch service issue events
    ${service_issue_cmd}=    RW.CLI.Run Bash File
    ...    bash_file=service-issue-event.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false

    # Read the output file
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat service_issue_events.json

    TRY
        ${event_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        ${event_list}=    Create List
    END

    ${service_issue_event_count}=    Get Length    ${event_list}
    Set Global Variable    ${service_issue_event_count}

    # Optional: Set a score variable (1 if no events, 0 otherwise)
    ${service_issue_event_score}=    Evaluate    1 if int(${service_issue_event_count}) == 0 else 0
    Set Global Variable    ${service_issue_event_score}


Count Azure Impacted Resources
    [Documentation]    Count the number of Azure resources currently impacted by planned maintenance or other events
    [Tags]    SLI    Azure    Impacted    access:read-only
    # Run the script to fetch impacted resources
    ${impacted_cmd}=    RW.CLI.Run Bash File
    ...    bash_file=impacted-resource.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false

    # Read the output file
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat impacted_resources.json

    TRY
        ${impacted_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        ${impacted_list}=    Create List
    END

    ${impacted_resource_count}=    Get Length    ${impacted_list}
    Set Global Variable    ${impacted_resource_count}

    # Optional: Set a score variable (1 if no impacted resources, 0 otherwise)
    ${impacted_resource_score}=    Evaluate    1 if int(${impacted_resource_count}) == 0 else 0
    Set Global Variable    ${impacted_resource_score}

Generate Health Score
    ${health_score}=    Evaluate  (${maintenance_event_score} + ${service_issue_event_score} + ${impacted_resource_score}) / 3
    ${health_score}=    Convert to Number    ${health_score}  2
    RW.Core.Push Metric    ${health_score}


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
    ${AZURE_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZURE_RESOURCE_GROUP
    ...    type=string
    ...    description=Azure resource group.
    ...    pattern=\w*
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}"}
    
    # Set Azure subscription context for Cloud Custodian
    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZURE_SUBSCRIPTION_ID}
    ...    include_in_history=false