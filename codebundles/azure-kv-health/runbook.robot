*** Settings ***
Documentation       List Key Vaults that are not available
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
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}"}