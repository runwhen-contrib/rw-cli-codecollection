*** Settings ***
Documentation       List Azure planned maintenance events, service issue events, and impacted resources
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
List Azure Planned Maintenance Events
    [Documentation]    List Azure planned maintenance events for the subscription
    [Tags]    Maintenance    Azure    access:read-only
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
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${event_list}=    Create List
    END

    IF    $event_list
        # Format the results for the report
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["TrackingId", "EventType", "Status", "Level", "ImpactStartTime", "ImpactMitigationTime", "Description"], (.[] | [ .trackingId, .eventType, .status, .level, .impactStartTime, .impactMitigationTime, (.description | gsub("\\n"; " ") | gsub("\\r"; "")) ]) | @tsv' maintenance_events.json | column -t -s $'\t'
        RW.Core.Add Pre To Report    Azure Planned Maintenance Events Summary:\n========================================\n${formatted_results.stdout}
        ${pretty_events}=    Evaluate    pprint.pformat(${event_list})    modules=pprint
        # Raise a single issue for all events
        ${event_count}=    Get Length    ${event_list}
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=No planned maintenance events should impact resources
        ...    actual=Found ${event_count} planned maintenance event(s)
        ...    title=Azure Planned Maintenance Events detected in subscription `${AZURE_SUBSCRIPTION_NAME}`
        ...    details={"maintenance_events": ${pretty_events}, "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
        ...    next_steps=Review the azure planned maintenance events in subscription `${AZURE_SUBSCRIPTION_NAME}`
    ELSE
        RW.Core.Add Pre To Report    "No planned maintenance events found in the subscription `${AZURE_SUBSCRIPTION_NAME}`"
    END

List Azure Service Issue Events
    [Documentation]    List Azure service issue events for the subscription
    [Tags]    Maintenance    Azure    access:read-only
    # Run the script to fetch maintenance events
    ${maintenance_cmd}=    RW.CLI.Run Bash File
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
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${event_list}=    Create List
    END

    IF    $event_list
        # Format the results for the report
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["TrackingId", "EventType", "Status", "Level", "ImpactStartTime", "ImpactMitigationTime", "Description"], (.[] | [ .trackingId, .eventType, .status, .level, .impactStartTime, .impactMitigationTime, (.description | gsub("\\n"; " ") | gsub("\\r"; "")) ]) | @tsv' service_issue_events.json | column -t -s $'\t'
        RW.Core.Add Pre To Report    Azure Service Issue Events Summary:\n========================================\n${formatted_results.stdout}
        ${pretty_events}=    Evaluate    pprint.pformat(${event_list})    modules=pprint
        # Raise a single issue for all events
        ${event_count}=    Get Length    ${event_list}
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=No service issue events should impact resources
        ...    actual=Found ${event_count} service issue event(s)    
        ...    title=Azure Service Issue Events detected in subscription `${AZURE_SUBSCRIPTION_NAME}`
        ...    details={"service_issue_events": ${pretty_events}, "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
        ...    next_steps=Review the azure service issue events in subscription `${AZURE_SUBSCRIPTION_NAME}`
    ELSE
        RW.Core.Add Pre To Report    "No service issue events found in the subscription `${AZURE_SUBSCRIPTION_NAME}`"
    END

List Azure Impacted Resources
    [Documentation]    List Azure resources impacted by planned maintenance or other events
    [Tags]    Maintenance    Azure    Impacted    access:read-only
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
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${impacted_list}=    Create List
    END

    IF    $impacted_list
        # Format the results for the report
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["ResourceName", "ResourceGroup", "ResourceType", "TrackingId", "SubscriptionId", "ResourceLink"], (.[] | [ .resourceName, .resourceGroup, .resourceType, .TrackingId, .subscriptionId, ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' impacted_resources.json | column -t -s $'\t'
        RW.Core.Add Pre To Report    Azure Impacted Resources Summary:\n========================================\n${formatted_results.stdout}

        # Raise a single issue for all impacted resources
        ${impacted_count}=    Get Length    ${impacted_list}
        ${pretty_impacted}=    Evaluate    pprint.pformat(${impacted_list})    modules=pprint
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=No Azure resources should be impacted by planned maintenance or other events
        ...    actual=Found ${impacted_count} impacted resource(s)
        ...    title=Azure Impacted Resources detected in subscription `${AZURE_SUBSCRIPTION_NAME}`
        ...    details={"impacted_resources": ${pretty_impacted}, "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
        ...    next_steps=Review the impacted resources in subscription `${AZURE_SUBSCRIPTION_NAME}`
    ELSE
        RW.Core.Add Pre To Report    "No impacted resources found for the subscription."
    END

*** Keywords ***
Suite Initialization
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    ${AZURE_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZURE_RESOURCE_GROUP
    ...    type=string
    ...    description=Azure resource group.
    ...    pattern=\w*
    ${AZURE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure Subscription ID for the resource.  
    ...    pattern=\w*
    ...    default=""
    ${AZURE_SUBSCRIPTION_NAME}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_NAME
    ...    type=string
    ...    description=The Azure Subscription Name for the resource.
    ...    pattern=\w*
    ...    default=""
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_NAME}    ${AZURE_SUBSCRIPTION_NAME}
    # Set Azure subscription context for Cloud Custodian
    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZURE_SUBSCRIPTION_ID}
    ...    include_in_history=false

    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}"}