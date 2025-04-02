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
Check Key Vault Availability in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
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

    ${issue_count}=    Set Variable    0
    FOR    ${metric}    IN    @{availability_data['metrics']}
        IF    '${metric['percentage']}' != 'N/A' and float(${metric['percentage']}) < 100
            ${issue_count}=    Evaluate    ${issue_count} + 1
        END
    END

    ${kv_availability_score}=    Evaluate    str(1 if ${issue_count} == 0 else 0)
    Set Global Variable    ${kv_availability_score}

Count Key Vault configuration in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Count Key vault's miss-configuration
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

    ${issue_count}=    Set Variable    0
    FOR    ${kv}    IN    @{config_data['keyVaults']}
        IF    '${kv['soft_delete']}' != 'true' or '${kv['purge_protection']}' != 'true'
            ${issue_count}=    Evaluate    ${issue_count} + 1
        END
    END

    ${kv_config_score}=    Evaluate    str(1 if ${issue_count} == 0 else 0)
    Set Global Variable    ${kv_config_score}


Count Expiring Key Vault Items in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Count expiring secrets, certificates, and keys in Key Vaults
    [Tags]    KeyVault    Azure    Expiry    access:read-only

    TRY
        ${expiry_data}=    Evaluate    json.load(open('kv_expiry_issues.json'))    json
    EXCEPT
        Log    Failed to load JSON file, defaulting to empty list.    WARN
        ${expiry_data}=    Create Dictionary    issues=[]
    END

    ${issue_count}=    Set Variable    len(${expiry_data['issues']})
    ${kv_expiry_score}=    Evaluate    str(1 if ${issue_count} == 0 else 0)
    Set Global Variable    ${kv_expiry_score}

Count Key Vault Log Issues in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Count Key Vault log issues
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

    ${issue_count}=    Set Variable    len(${log_data['issues']})
    ${kv_log_score}=    Evaluate    str(1 if ${issue_count} == 0 else 0)
    Set Global Variable    ${kv_log_score}

Generate Comprehensive Key Vault Health Score
    ${kv_health_score}=    Evaluate    (float(${kv_availability_score}) + float(${kv_config_score}) + float(${kv_expiry_score}) + float(${kv_log_score})) / 4
    ${health_score}=    Convert to Number    ${kv_health_score}    2
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