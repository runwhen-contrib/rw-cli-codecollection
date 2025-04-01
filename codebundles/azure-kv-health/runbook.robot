*** Settings ***
Documentation       Monitors and reports on Azure Key Vault health metrics including availability, authentication failures, certificate/secret/keys expiration and key vaults failed logs 
Metadata            Author    saurabh3460
Metadata            Display Name    Azure Key Vault Health
Metadata            Supports    Azure    Key Vault    Health
Force Tags          Azure    Key Vault    Health

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
List Key Vault Availability in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    List availability metrics for Key Vaults in the resource group
    [Tags]    KeyVault    Azure    Health    Monitoring    access:read-only
    ${availability_output}=    RW.CLI.Run Bash File
    ...    bash_file=availability.sh
    ...    env=${env}
    ...    secret__azure_credentials=${azure_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false

    TRY
        ${availability_data}=    Evaluate    json.loads(r'''${availability_output.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${availability_data}=    Create Dictionary    metrics=[]
    END

    IF    len(${availability_data['metrics']}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["KeyVault_Name", "Availability_Percentage"], (.metrics[] | [ .kv_name, .percentage ]) | @tsv' <<< '${availability_output.stdout}' | column -t
        RW.Core.Add Pre To Report    Key Vault Availability Summary:\n==============================\n${formatted_results.stdout}

        FOR    ${kv}    IN    @{availability_data['metrics']}
            ${kv_name}=    Set Variable    ${kv['kv_name']}
            ${percentage}=    Set Variable    ${kv['percentage']}
            IF    '${percentage}' != 'N/A' and float(${percentage}) < 100
                RW.Core.Add Issue
                ...    severity=2
                ...    expected=Key Vault `${kv_name}` should have 100% availability in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    actual=Key Vault `${kv_name}` has ${percentage}% availability in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    title=Key Vault `${kv_name}` Availability Below 100% in Resource Group `${AZURE_RESOURCE_GROUP}`
                ...    reproduce_hint=${availability_output.cmd}
                ...    next_steps=Investigate the Key Vault `${kv_name}` for potential issues in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            END
        END
    ELSE
        RW.Core.Add Pre To Report    "No Key Vault availability data found in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`"
    END

Check Key Vault Configuration in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    List configuration details for Key Vaults in the resource group
    [Tags]    KeyVault    Azure    Configuration    access:read-only
    ${config_output}=    RW.CLI.Run Bash File
    ...    bash_file=kv_config.sh
    ...    env=${env}
    ...    secret__azure_credentials=${azure_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false

    TRY
        ${config_data}=    Evaluate    json.loads(r'''${config_output.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${config_data}=    Create Dictionary    keyVaults=[]
    END

    IF    len(${config_data['keyVaults']}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["KeyVault_Name", "Soft_Delete", "Purge_Protection", "Resource_URL"], (.keyVaults[] | [ .kv_name, .soft_delete, .purge_protection, .resource_url ]) | @tsv' <<< '${config_output.stdout}' | column -t
        RW.Core.Add Pre To Report    Key Vault Configuration Summary:\n==============================\n${formatted_results.stdout}

        FOR    ${kv}    IN    @{config_data['keyVaults']}
            ${kv_name}=    Set Variable    ${kv['kv_name']}
            ${soft_delete}=    Set Variable    ${kv['soft_delete']}
            ${purge_protection}=    Set Variable    ${kv['purge_protection']}
            ${resource_url}=    Set Variable    ${kv['resource_url']}
            
            IF    '${soft_delete}' != 'true'
                RW.Core.Add Issue
                ...    severity=2
                ...    expected=Key Vault `${kv_name}` should have Soft Delete enabled in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    actual=Key Vault `${kv_name}` has Soft Delete set to ${soft_delete} in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    title=Key Vault `${kv_name}` Soft Delete Not Enabled in Resource Group `${AZURE_RESOURCE_GROUP}`
                ...    reproduce_hint=${config_output.cmd}
                ...    next_steps=Enable Soft Delete for Key Vault `${kv_name}` in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            END
            
            IF    '${purge_protection}' != 'true'
                RW.Core.Add Issue
                ...    severity=1
                ...    expected=Key Vault `${kv_name}` should have Purge Protection enabled in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    actual=Key Vault `${kv_name}` has Purge Protection set to ${purge_protection} in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    title=Key Vault `${kv_name}` Purge Protection Not Enabled in Resource Group `${AZURE_RESOURCE_GROUP}`
                ...    reproduce_hint=${config_output.cmd}
                ...    next_steps=Consider enabling Purge Protection for Key Vault `${kv_name}` in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            END
        END
    ELSE
        RW.Core.Add Pre To Report    "No Key Vaults found in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`"
    END

Check Expiring Key Vault Items in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Check for expiring secrets, certificates, and keys in Key Vaults
    [Tags]    KeyVault    Azure    Expiry    access:read-only
    ${expiry_output}=    RW.CLI.Run Bash File
    ...    bash_file=expiry-checks.sh
    ...    env=${env}
    ...    secret__azure_credentials=${azure_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false

    TRY
        ${expiry_data}=    Evaluate    json.loads(r'''${expiry_output.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${expiry_data}=    Create List
    END

    IF    len(${expiry_data}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["KeyVault", "ResourceGroup", "Type", "Name", "RemainingDays"], (.[] | [ .keyVault, .resourceGroup, .type, .name, .remainingDays ]) | @tsv' <<< '${expiry_output.stdout}' | column -t
        RW.Core.Add Pre To Report    Expiring Key Vault Items Summary:\n==================================\n${formatted_results.stdout}

        FOR    ${item}    IN    @{expiry_data}
            ${kv_name}=    Set Variable    ${item['keyVault']}
            ${resource_group}=    Set Variable    ${item['resourceGroup']}
            ${type}=    Set Variable    ${item['type']}
            ${name}=    Set Variable    ${item['name']}
            ${remaining_days}=    Set Variable    ${item['remainingDays']}
            
            IF    ${remaining_days} == 0
                RW.Core.Add Issue
                ...    severity=1
                ...    expected=${type} `${name}` in Key Vault `${kv_name}` should be renewed before expiration in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    actual=${type} `${name}` in Key Vault `${kv_name}` has expired in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    title=Expired ${type} in Key Vault `${kv_name}` in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    reproduce_hint=${expiry_output.cmd}
                ...    next_steps=Immediately renew or rotate ${type} `${name}` in Key Vault in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ELSE IF    ${remaining_days} > 0 and ${remaining_days} < ${THRESHOLD_DAYS}
                RW.Core.Add Issue
                ...    severity=3
                ...    expected=${type} `${name}` in Key Vault `${kv_name}` should be renewed before expiration in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    actual=${type} `${name}` in Key Vault `${kv_name}` will expire in ${remaining_days} days in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    title=${type} Nearing Expiration in Key Vault `${kv_name}` in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    reproduce_hint=${expiry_output.cmd}
                ...    next_steps=Renew or rotate ${type} `${name}` in Key Vault `${kv_name}` in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}` before expiration
            END
        END
    ELSE
        RW.Core.Add Pre To Report    "No expiring items found in Key Vaults in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`"
    END


Check Key Vault Logs for Issues in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Check Key Vault logs for authentication failures and expired secrets/keys
    [Tags]    KeyVault    Azure    Logs    access:read-only
    ${cmd}=    RW.CLI.Run Bash File
    ...    bash_file=log.sh
    ...    env=${env}
    ...    secret__azure_credentials=${azure_credentials}
    ...    timeout_seconds=300
    ...    include_in_history=false

    TRY
        ${log_data}=    Evaluate    json.load(open('kv_log_issues.json'))    json
    EXCEPT
        Log    Failed to load JSON file, defaulting to empty list.    WARN
        ${log_data}=    Create Dictionary    issues=[]
    END

    IF    len(${log_data['issues']}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["Operation", "HTTP-Status", "Client-Info", "IP", "ID", "Description"], (.issues[] | .details[] | [(.operation // ""), (.httpStatusCode // ""), (.clientInfo // "" | gsub(" "; "_")), (.ip // ""), (.id // ""), (.resultDescription // "")]) | @tsv' kv_log_issues.json | column -t
        RW.Core.Add Pre To Report    Key Vault Log Issues Summary:\n================================\n${formatted_results.stdout}

        FOR    ${issue}    IN    @{log_data['issues']}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=No issues found in Key Vault logs in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    actual=${issue['title']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${cmd.cmd}
            ...    next_steps=${issue['next_step']}
            ...    details=${issue['details']}
        END
    ELSE
        RW.Core.Add Pre To Report    "No issues found in Key Vault logs in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`"
    END
    ${remove_file}=    RW.CLI.Run Cli
    ...    cmd=rm -f kv_log_issues.json

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
    ${THRESHOLD_DAYS}=    RW.Core.Import User Variable    THRESHOLD_DAYS
    ...    type=integer
    ...    description=Number of days before expiration to trigger alerts
    ...    default=31
    Set Suite Variable    ${AZURE_SUBSCRIPTION_NAME}    ${AZURE_SUBSCRIPTION_NAME}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${THRESHOLD_DAYS}    ${THRESHOLD_DAYS}
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}", "AZURE_SUBSCRIPTION_NAME":"${AZURE_SUBSCRIPTION_NAME}", "THRESHOLD_DAYS":"${THRESHOLD_DAYS}"}