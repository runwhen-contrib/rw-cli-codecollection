*** Settings ***
Documentation       Check Azure planned maintenance events
Metadata            Author    saurabh3460
Metadata            Display Name    Azure    Planned Maintenance
Metadata            Supports    Azure    Planned Maintenance
Force Tags          Azure    Planned Maintenance

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library    CloudCustodian.Core
Library    OperatingSystem
Library    Collections
Library    DateTime
Suite Setup         Suite Initialization


*** Tasks ***
List Unused Azure Disks in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    List Azure disks that are not attached to any VM
    [Tags]    Disk    Azure    Storage    Cost    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/unused-disk.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ...    subscriptionId=${AZURE_SUBSCRIPTION_ID}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-disk-triage ${CURDIR}/unused-disk.yaml --cache-period 0
    ...    timeout_seconds=180
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-disk-triage/unused-disk/resources.json

    TRY
        ${disk_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${disk_list}=    Create List
    END

    IF    $disk_list
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["Disk_Name", "Resource_Group", "Location", "Size_GB", "Disk_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), .location, .properties.diskSizeGB, ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-disk-triage/unused-disk/resources.json | column -t
        RW.Core.Add Pre To Report    Unused Disks Summary:\n========================\n${formatted_results.stdout}

        FOR    ${disk}    IN    @{disk_list}
            ${pretty_disk}=    Evaluate    pprint.pformat(${disk})    modules=pprint
            ${resource_group}=    Set Variable    ${disk['resourceGroup'].lower()}
            ${disk_name}=    Set Variable    ${disk['name']}
            ${disk_size}=    Set Variable    ${disk['properties']['diskSizeGB']}
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Azure disk `${disk_name}` should be attached to a VM in resource group `${resource_group}` 
            ...    actual=Azure disk `${disk_name}` is not attached to any VM in resource group `${resource_group}` 
            ...    title=Unused Azure Disk `${disk_name}` found in Resource Group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details={ "details": ${pretty_disk}, "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
            ...    next_steps=Delete the unused disk to reduce storage costs in resource group `${resource_group}` 
        END
    ELSE
        RW.Core.Add Pre To Report    "No unused disks found in resource group `${AZURE_RESOURCE_GROUP}`"
    END

List Unused Azure Snapshots in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    List Azure snapshots that are not attached
    [Tags]    Snapshot    Azure    Storage    Cost    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/unused-snapshot.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ...    subscriptionId=${AZURE_SUBSCRIPTION_ID}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-snapshot-triage ${CURDIR}/unused-snapshot.yaml --cache-period 0
    ...    timeout_seconds=180
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-snapshot-triage/unused-snapshot/resources.json

    TRY
        ${snapshot_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${snapshot_list}=    Create List
    END

    IF    $snapshot_list
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["Snapshot_Name", "Resource_Group", "Location", "Size_GB", "Snapshot_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), .location, .properties.diskSizeGB, ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-snapshot-triage/unused-snapshot/resources.json | column -t
        RW.Core.Add Pre To Report    Unused Snapshots Summary:\n========================\n${formatted_results.stdout}

        FOR    ${snapshot}    IN    @{snapshot_list}
            ${pretty_snapshot}=    Evaluate    pprint.pformat(${snapshot})    modules=pprint
            ${resource_group}=    Set Variable    ${snapshot['resourceGroup'].lower()}
            ${snapshot_name}=    Set Variable    ${snapshot['name']}
            ${snapshot_size}=    Set Variable    ${snapshot['properties']['diskSizeGB']}
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Azure snapshot `${snapshot_name}` should be attached to a disk in resource group `${resource_group}` 
            ...    actual=Azure snapshot `${snapshot_name}` is not attached to any disk in resource group `${resource_group}` 
            ...    title=Unused Azure Snapshot `${snapshot_name}` found in Resource Group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details={ "details": ${pretty_snapshot}, "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
            ...    next_steps=Delete the unused snapshot to reduce storage costs in resource group `${resource_group}` 
        END
    ELSE
        RW.Core.Add Pre To Report    "No unused snapshots found in resource group `${AZURE_RESOURCE_GROUP}`"
    END

List Unused Azure Storage Accounts in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    List Azure storage accounts with no transactions
    [Tags]    Storage    Azure    Cost    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/unused-storage-account.j2
    ...    timeframe=${UNUSED_STORAGE_ACCOUNT_TIMEFRAME}
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ...    subscriptionId=${AZURE_SUBSCRIPTION_ID}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-storage-triage ${CURDIR}/unused-storage-account.yaml --cache-period 0
    ...    timeout_seconds=180
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-storage-triage/unused-storage-account/resources.json

    TRY
        ${storage_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${storage_list}=    Create List
    END

    IF    $storage_list
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["Storage_Name", "Resource_Group", "Location", "Transactions", "Storage_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), .location, (."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // 0 | tonumber | (. * 100 | round / 100) | tostring), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-storage-triage/unused-storage-account/resources.json | column -t
        RW.Core.Add Pre To Report    Unused Storage Accounts Summary:\n========================\n${formatted_results.stdout}

        FOR    ${storage}    IN    @{storage_list}
            ${pretty_storage}=    Evaluate    pprint.pformat(${storage})    modules=pprint
            ${resource_group}=    Set Variable    ${storage['resourceGroup'].lower()}
            ${storage_name}=    Set Variable    ${storage['name']}
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Azure storage account `${storage_name}` should have transactions in resource group `${resource_group}` 
            ...    actual=Azure storage account `${storage_name}` has no transactions in the last `${UNUSED_STORAGE_ACCOUNT_TIMEFRAME}` hours in resource group `${resource_group}` 
            ...    title=Unused Azure Storage Account `${storage_name}` found in Resource Group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details={ "details": ${pretty_storage}, "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
            ...    next_steps=Delete the unused storage account to reduce storage costs in resource group `${resource_group}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No unused storage accounts found in resource group `${AZURE_RESOURCE_GROUP}`"
    END

List Storage Containers with Public Access in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    List Azure storage containers with public access enabled
    [Tags]    Storage    Azure    Security    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    stg-containers-with-public-access.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ...    subscriptionId=${AZURE_SUBSCRIPTION_ID}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s azure-c7n-storage-containers-public-access stg-containers-with-public-access.yaml --cache-period 0
    ...    timeout_seconds=180
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat azure-c7n-storage-containers-public-access/storage-container-public/resources.json
    TRY
        ${container_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${container_list}=    Create List
    END

    IF    $container_list
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["Container_Name","Storage_Account","Resource_Group","Public_Access_Level","Container_Link"], (.[] | [ .name,(.id | split("/") | .[8] // ""), (.resourceGroup | ascii_downcase), (.properties.publicAccess), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' azure-c7n-storage-containers-public-access/storage-container-public/resources.json | column -s $'\t' -t 
        RW.Core.Add Pre To Report    Public Accessible Storage Containers Summary:\n========================\n${formatted_results.stdout}

        FOR    ${container}    IN    @{container_list}
            ${pretty_container}=    Evaluate    pprint.pformat(${container})    modules=pprint
            ${resource_group}=    Set Variable    ${container['resourceGroup'].lower()}
            ${container_name}=    Set Variable    ${container['name']}
            ${public_access}=    Set Variable    ${container['properties']['publicAccess']}
            ${access_description}=    Set Variable If
            ...    '${public_access}' == 'Container'    Public read access to entire container
            ...    '${public_access}' == 'Blob'    Public read access to blobs only
            ...    Unknown public access level
            
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Azure storage container `${container_name}` should have restricted public access in resource group `${resource_group}`
            ...    actual=Azure storage container `${container_name}` has public access level '${public_access}' (${access_description}) in resource group `${resource_group}`
            ...    title=Public Accessible Azure Storage Container `${container_name}` found in Resource Group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details={ "details": ${pretty_container}, "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
            ...    next_steps=Restrict public access to the storage container to improve security in resource group `${resource_group}`.
        END
    ELSE
        RW.Core.Add Pre To Report    "No public accessible storage containers found in resource group `${AZURE_RESOURCE_GROUP}`"
    END

List Storage Account Misconfigurations in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Identify Azure storage accounts with security or configuration misconfigurations
    [Tags]    Storage    Azure    Security    Configuration    access:read-only

    # Execute the helper script that generates `storage_misconfig.json`
    ${misconfig_cmd}=    RW.CLI.Run Bash File
    ...    bash_file=storage-misconfig.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false

    ${log_file}=    Set Variable    storage_misconfig.json
    ${misconfig_output}=    RW.CLI.Run Cli
    ...    cmd=cat ${log_file}
    # Load JSON results.  If the file is missing or malformed, report an issue and abort.
    TRY
        ${data}=    Evaluate    json.loads('''${misconfig_output.stdout}''')    json
    EXCEPT    Exception as e
        Log    Failed to load JSON payload, defaulting to empty result set. Error: ${str(e)}    WARN
        ${data}=    Create Dictionary    storage_accounts=[]
    END

    ${accounts}=    Set Variable    ${data.get('storage_accounts', [])}

    IF    $accounts
        FOR    ${acct}    IN    @{accounts}
            ${acct_name}=    Set Variable    ${acct['name']}
            ${acct_url}=    Set Variable    ${acct.get('resource_url', 'N/A')}
            ${issues}=    Set Variable    ${acct.get('issues', [])}
            ${acct_pretty}=    Evaluate    json.dumps(${acct}, indent=2)
            
            # Skip if no issues
            IF    not ${issues}
                CONTINUE
            END
            
            # Prepare combined issue details
            ${issue_descriptions}=    Create List
            ${next_steps_list}=    Create List
            
            FOR    ${issue}    IN    @{issues}
                ${issue_details}=    Catenate    SEPARATOR=\n\n
                ...    Issue: ${issue.get('title', 'Misconfiguration')}
                ...    Reason: ${issue.get('reason', 'No reason provided')}
                
                ${step}=    Set Variable    ${issue.get('next_step', 'Review and remediate this misconfiguration.')}
                Append To List    ${next_steps_list}    ${step}
                
                Append To List    ${issue_descriptions}    ${issue_details}
            END
            
            # Build tabular misconfiguration list using jq and column
            ${issues_json}=    Evaluate    json.dumps(${issues})    json
            ${issues_table}=    RW.CLI.Run Cli
            ...    cmd=echo '${issues_json}' | jq -r '"Issue\tReason", "----------\t-----------", (.[] | [.title, (.reason // "No reason provided")] | @tsv)' | column -s "\t" -t
            ${combined_issues}=    Set Variable    ${issues_table.stdout}

            # Combine all next steps into a single multiline string
            ${combined_next_steps}=    Evaluate    '\\n'.join(${next_steps_list})

            # Get issue count
            ${issue_count}=    Get Length    ${issues}
            RW.Core.Add Pre To Report    \nMisconfigurations in storage account ${acct_name}:\n====================================================\n${combined_issues}
            # Create a single issue for this storage account
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Storage account `${acct_name}` should not have security misconfigurations in resource group `${AZURE_RESOURCE_GROUP}`
            ...    actual=Found ${issue_count} misconfiguration(s) in storage account `${acct_name}` in resource group `${AZURE_RESOURCE_GROUP}`
            ...    title=Azure Storage Misconfiguration found in ${acct_name} in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${misconfig_cmd.cmd}
            ...    next_steps=${combined_next_steps}
            ...    details={ "storage_account": ${acct_pretty}, "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
        END

        # Calculate overall totals
        ${total_issues}=    Set Variable    0
        ${EMPTY_LIST}=    Create List
        FOR    ${acct}    IN    @{accounts}
            ${issues}=    Get From Dictionary    ${acct}    issues    ${EMPTY_LIST}
            ${cnt}=    Get Length    ${issues}
            ${total_issues}=    Evaluate    ${total_issues} + ${cnt}
        END
        ${account_count}=    Get Length    ${accounts}
        RW.Core.Add Pre To Report    Detected ${total_issues} misconfiguration(s) across ${account_count} storage account(s) in resource group `${AZURE_RESOURCE_GROUP}`
    ELSE
        RW.Core.Add Pre To Report    "No storage account misconfigurations found in resource group `${AZURE_RESOURCE_GROUP}`"
    END

List Storage Account Changes in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Lists storage account changes and operations from Azure Activity Log
    [Tags]    Storage    Azure    Audit    Security    access:read-only
    
    ${success_file}=    Set Variable    ${CURDIR}/stg_changes_success.json
    ${failed_file}=    Set Variable    ${CURDIR}/stg_changes_failed.json
    
    ${audit_cmd}=    RW.CLI.Run Bash File
    ...    bash_file=stg-audit.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    # Process successful operations
    ${success_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${success_file}
    TRY
        ${success_changes}=    Evaluate    json.loads(r'''${success_data.stdout}''')    json
    EXCEPT
        Log    Failed to load successful changes JSON, defaulting to empty dict.    WARN
        ${success_changes}=    Create Dictionary
    END

    # Process failed operations
    ${failed_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${failed_file}
    TRY
        ${failed_changes}=    Evaluate    json.loads(r'''${failed_data.stdout}''')    json
    EXCEPT
        Log    Failed to load failed changes JSON, defaulting to empty dict.    WARN
        ${failed_changes}=    Create Dictionary
    END

    # Process successful changes
    ${success_length}=    Get Length    ${success_changes}
    IF    ${success_length} > 0
        FOR    ${stg_name}    IN    @{success_changes.keys()}
            ${stg_changes}=    Set Variable    ${success_changes["${stg_name}"]}
            ${stg_changes_length}=    Get Length    ${stg_changes}
            
            # Skip if no changes for this storage account
            IF    ${stg_changes_length} == 0
                CONTINUE
            END
            
            # Format changes for this storage account
            ${stg_changes_json}=    Evaluate    json.dumps(${stg_changes})    json
            ${formatted_results}=    RW.CLI.Run Cli
            ...    cmd=printf '%s' '${stg_changes_json}' | jq -r '["Operation", "Timestamp", "Caller", "Security_Level", "Reason"] as $headers | [$headers] + [.[] | [.operation, .timestamp, .caller, .security_classification, .reason]] | .[] | @tsv' | column -t -s $'\t'
            RW.Core.Add Pre To Report    Successful Changes for Storage Account (${stg_name}):\n-------------------------------------------------------\n${formatted_results.stdout}\n
            
            # Raise issues for changes based on security classification
            FOR    ${change}    IN    @{stg_changes}
                ${pretty_change}=    Evaluate    pprint.pformat(${change})    modules=pprint
                ${operation}=    Set Variable    ${change['operation']}
                ${caller}=    Set Variable    ${change['caller']}
                ${timestamp}=    Set Variable    ${change['timestamp']}
                ${security_level}=    Set Variable    ${change['security_classification']}
                ${reason}=    Set Variable    ${change['reason']}
                ${resource_url}=    Set Variable    ${change['resourceUrl']}
                
                # Map security classification to severity
                ${severity}=    Set Variable If
                ...    '${security_level}' == 'Critical'    3
                ...    '${security_level}' == 'High'        3
                ...    '${security_level}' == 'Medium'      4
                ...    4
                
                # Add portal URL to details
                ${enhanced_details}=    Set Variable    ${pretty_change}\n\nAzure Portal Link: ${resource_url}
                
                RW.Core.Add Issue
                ...    severity=${severity}
                ...    expected=Storage account operations should be reviewed for security implications in resource group `${AZURE_RESOURCE_GROUP}`
                ...    actual=${security_level.lower()} security operation detected: ${operation} by ${caller} at ${timestamp} on storage account `${stg_name}`
                ...    title=Storage Account Change - ${security_level} Security: ${operation} on `${stg_name}` in Resource Group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    details={ "details": ${enhanced_details}, "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
                ...    reproduce_hint=${audit_cmd.cmd}
                ...    next_steps=Review the operation for security implications. Reason: ${reason}
            END
        END
    ELSE
        RW.Core.Add Pre To Report    No successful storage account changes found in resource group `${AZURE_RESOURCE_GROUP}` within the specified timeframe
    END

    # Process failed changes
    ${failed_length}=    Get Length    ${failed_changes}
    IF    ${failed_length} > 0
        FOR    ${stg_name}    IN    @{failed_changes.keys()}
            ${stg_changes}=    Set Variable    ${failed_changes["${stg_name}"]}
            ${stg_changes_length}=    Get Length    ${stg_changes}
            
            # Skip if no changes for this storage account
            IF    ${stg_changes_length} == 0
                CONTINUE
            END
            
            # Format changes for this storage account
            ${stg_changes_json}=    Evaluate    json.dumps(${stg_changes})    json
            ${formatted_results}=    RW.CLI.Run Cli
            ...    cmd=printf '%s' '${stg_changes_json}' | jq -r '["Operation", "Timestamp", "Caller", "Security_Level", "Reason"] as $headers | [$headers] + [.[] | [.operation, .timestamp, .caller, .security_classification, .reason]] | .[] | @tsv' | column -t -s $'\t'
            RW.Core.Add Pre To Report    Failed Changes for Storage Account (${stg_name}):\n-----------------------------------------------------\n${formatted_results.stdout}\n
            
            # Raise issues for changes based on security classification
            FOR    ${change}    IN    @{stg_changes}
                ${pretty_change}=    Evaluate    pprint.pformat(${change})    modules=pprint
                ${operation}=    Set Variable    ${change['operation']}
                ${caller}=    Set Variable    ${change['caller']}
                ${timestamp}=    Set Variable    ${change['timestamp']}
                ${security_level}=    Set Variable    ${change['security_classification']}
                ${reason}=    Set Variable    ${change['reason']}
                ${resource_url}=    Set Variable    ${change['resourceUrl']}
                
                # Add portal URL to details
                ${enhanced_details}=    Set Variable    ${pretty_change}\n\nAzure Portal Link: ${resource_url}
                
                RW.Core.Add Issue
                ...    severity=4
                ...    expected=Storage account operations should complete successfully in resource group `${AZURE_RESOURCE_GROUP}`
                ...    actual=Failed operation detected: ${operation} by ${caller} at ${timestamp} on storage account `${stg_name}`
                ...    title=Storage Account Failed Operation: ${operation} on `${stg_name}` in Resource Group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    details={ "details": ${enhanced_details}, "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
                ...    reproduce_hint=${audit_cmd.cmd}
                ...    next_steps=Investigate the failed operation. Reason: ${reason}
            END
        END
    ELSE
        RW.Core.Add Pre To Report    No failed storage account changes found in resource group `${AZURE_RESOURCE_GROUP}` within the specified timeframe
    END
    
    # Clean up temporary files
    RW.CLI.Run Cli    cmd=rm -f ${success_file} ${failed_file}



Check Azure Planned Maintenance Events
    [Documentation]    Check for any planned maintenance events in Azure
    [Tags]    Maintenance    Azure    Health    access:read-only
    
    # Set output file path
    ${output_file}=    Set Variable    ${CURDIR}/maintenance_events.json
    
    # Run Azure CLI command to get maintenance events
    ${result}=    RW.CLI.Run Cli
    ...    cmd=az maintenance update list --query "[?status == 'Scheduled' || status == 'InProgress' || status == 'Pending']" -o json > ${output_file}
    ...    env={"AZURE_CLIENT_ID": "${AZURE_CLIENT_ID}", "AZURE_TENANT_ID": "${AZURE_TENANT_ID}", "AZURE_CLIENT_SECRET": "${AZURE_CLIENT_SECRET}", "AZURE_SUBSCRIPTION_ID": "${AZURE_SUBSCRIPTION_ID}"}
    ...    timeout_seconds=60
    
    # Check if the file was created and has content
    ${file_exists}=    Run Keyword And Return Status    File Should Exist    ${output_file}
    IF    not ${file_exists}
        RW.Core.Add Pre To Report    No maintenance events file was created. There might be no maintenance events or an error occurred.
        RETURN
    END
    
    ${file_content}=    Get File    ${output_file}
    ${file_length}=    Get Length    ${file_content}
    
    IF    ${file_length} == 0
        RW.Core.Add Pre To Report    No planned maintenance events found.
    ELSE
        # Parse the JSON to get maintenance events
        ${maintenance_events}=    Evaluate    json.loads(r'''${file_content}''')    json
        ${event_count}=    Get Length    ${maintenance_events}
        
        RW.Core.Add Pre To Report    Found ${event_count} planned maintenance event(s).
        
        # Process each maintenance event
        FOR    ${event}    IN    @{maintenance_events}
            ${event_status}=    Set Variable    ${event['status']}
            ${event_name}=    Set Variable    ${event.get('name', 'Unnamed Event')}
            ${impact_start}=    Set Variable    ${event.get('impactStartTime', 'Not specified')}
            ${impact_end}=    Set Variable    ${event.get('impactEndTime', 'Not specified')}
            ${impact_type}=    Set Variable    ${event.get('impactType', 'Not specified')}
            
            # Get impacted services and regions
            ${impact_details}=    Set Variable    ${event.get('impactedServices', [])}
            ${impacted_services}=    Create List
            
            FOR    ${service}    IN    @{impact_details}
                ${service_name}=    Set Variable    ${service.get('serviceName', 'Unknown Service')}
                ${regions}=    Set Variable    ${service.get('impactedRegions', [])}
                ${region_names}=    Create List
                
                FOR    ${region}    IN    @{regions}
                    Append To List    ${region_names}    ${region.get('regionName', 'Unknown Region')}
                END
                
                ${service_info}=    Set Variable    ${service_name}: ${', '.join(${region_names})}
                Append To List    ${impacted_services}    ${service_info}
            END
            
            # Format the impact details
            ${formatted_impact}=    Set Variable    ${\n}    
            # Add issue to report
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=No planned maintenance events
            ...    actual=Planned maintenance event: ${event_name}
            ...    title=Planned Maintenance: ${event_name} (${event_status})
            ...    details={
            ...    "status": "${event_status}",
            ...    "impact_start": "${impact_start}",
            ...    "impact_end": "${impact_end}",
            ...    "impact_type": "${impact_type}",
            ...    "impacted_services": ${impacted_services},
            ...    "subscription_id": "${AZURE_SUBSCRIPTION_ID}",
            ...    "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"
            ...    }
            ...    next_steps=Review the maintenance event details and plan accordingly. Check the Azure Portal for more information.
        END
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
    ${UNUSED_STORAGE_ACCOUNT_TIMEFRAME}=    RW.Core.Import User Variable    UNUSED_STORAGE_ACCOUNT_TIMEFRAME
    ...    type=string
    ...    description=The timeframe in hours to check for unused storage accounts (e.g., 720 for 30 days)
    ...    pattern=\d+
    ...    default=24
    ${AZURE_ACTIVITY_LOG_LOOKBACK}=    RW.Core.Import User Variable    AZURE_ACTIVITY_LOG_LOOKBACK
    ...    type=string
    ...    description=The time offset to check for activity logs in this formats 24h, 1h, 1d etc.
    ...    pattern=^\w+$
    ...    example=24h
    ...    default=24h
    ${AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE}=    RW.Core.Import User Variable    AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE
    ...    type=string
    ...    description=The time offset to check for activity logs in this formats 24h, 1h, 1d etc.
    ...    pattern=^\w+$
    ...    example=24h
    ...    default=24h
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${UNUSED_STORAGE_ACCOUNT_TIMEFRAME}    ${UNUSED_STORAGE_ACCOUNT_TIMEFRAME}
    Set Suite Variable    ${AZURE_ACTIVITY_LOG_LOOKBACK}    ${AZURE_ACTIVITY_LOG_LOOKBACK}
    Set Suite Variable    ${AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE}    ${AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_NAME}    ${AZURE_SUBSCRIPTION_NAME}
    # Set Azure subscription context for Cloud Custodian
    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZURE_SUBSCRIPTION_ID}
    ...    include_in_history=false
    
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}", "AZURE_ACTIVITY_LOG_OFFSET":"${AZURE_ACTIVITY_LOG_LOOKBACK}", "AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE":"${AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE}", "FILE_PREFIX":"${CURDIR}/"}
