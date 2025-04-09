*** Settings ***
Documentation       Check Azure Key Vault health by checking availability metrics, configuration settings, expiring items (secrets/certificates/keys), log issues, and performance metrics
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
Check Key Vault Resource Health in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Check the health status of Key Vaults in the specified resource group
    [Tags]    KeyVault    Azure    Health    access:read-only
    ${resource_health}=    RW.CLI.Run Bash File
    ...    bash_file=kv_resource_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true

    ${issue_list}=    Evaluate    json.loads(open('${CODEBUNDLE_TEMP_DIR}/keyvault_health.json').read())    json

    IF    len(@{issue_list}) > 0
        FOR    ${kv_health}    IN    @{issue_list}
            IF    "${kv_health['properties']['title']}" != "Available"
                RW.Core.Add Issue
                ...    severity=2
                ...    expected=Key Vault should be available in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    actual=Key Vault is unhealthy in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    title=Azure reports an `${kv_health['properties']['title']}` Issue for Key Vault in resource group `${AZURE_RESOURCE_GROUP}`
                ...    reproduce_hint=${resource_health.cmd}
                ...    details=${kv_health}
                ...    next_steps=Please escalate to the Azure service owner or check back later.
            END
        END
    ELSE
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Key Vault health should be enabled in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
        ...    actual=Key Vault health appears unavailable in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
        ...    title=Azure resource health is unavailable for Key Vault in resource group `${AZURE_RESOURCE_GROUP}`
        ...    reproduce_hint=${resource_health.cmd}
        ...    details=${issue_list}
        ...    next_steps=Please escalate to the Azure service owner to enable provider Microsoft.ResourceHealth.
    END

Check Key Vault Availability in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    List number of Azure key vault vaults with availability below 100% 
    [Tags]    KeyVault    Azure    Health    Monitoring    access:read-only
    ${availability_output}=    RW.CLI.Run Bash File
    ...    bash_file=availability.sh
    ...    env=${env}
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
                ...    severity=3
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
    [Documentation]    List Key Vault miss-configuration
    [Tags]    KeyVault    Azure    Configuration    access:read-only
    ${config_output}=    RW.CLI.Run Bash File
    ...    bash_file=kv_config.sh
    ...    env=${env}
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
                ...    severity=4
                ...    expected=Key Vault `${kv_name}` should have Soft Delete enabled in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    actual=Key Vault `${kv_name}` has Soft Delete set to ${soft_delete} in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    title=Key Vault `${kv_name}` Soft Delete Not Enabled in Resource Group `${AZURE_RESOURCE_GROUP}`
                ...    reproduce_hint=${config_output.cmd}
                ...    next_steps=Enable Soft Delete for Key Vault `${kv_name}` in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            END
            
            IF    '${purge_protection}' != 'true'
                RW.Core.Add Issue
                ...    severity=4
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

    # Run expiry checks script which generates kv_expiry_issues.json
    ${expiry_output}=    RW.CLI.Run Bash File
    ...    bash_file=expiry-checks.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    # Load issues from generated JSON file
    TRY
        ${expiry_data}=    Evaluate    json.load(open('${CODEBUNDLE_TEMP_DIR}/kv_expiry_issues.json'))    json
    EXCEPT
        Log    Failed to load JSON file, defaulting to empty list.    WARN
        ${expiry_data}=    Create Dictionary    issues=[]
    END

    IF    len(${expiry_data['issues']}) > 0
        # Format and display results
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["Name", "Item", "Resource-URL", "Remaining-Days"], (.issues[] | [ .name, .item, .resource_url, .remaining_days ]) | @tsv' kv_expiry_issues.json | column -t
        RW.Core.Add Pre To Report    Key Vault Expiry Issues Summary:\n===================================\n${formatted_results.stdout}

        # Create issues for each finding
        FOR    ${issue}    IN    @{expiry_data['issues']}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Azure Key Vault should not contain any expired or expiring secrets, certificates, or keys in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    actual=${issue['title']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${expiry_output.cmd}
            ...    next_steps=${issue['next_step']}
            ...    details=${issue['details']}
        END
    ELSE
        RW.Core.Add Pre To Report    "No expiring items found in Key Vaults in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`"
    END

    # Clean up generated file
    ${remove_file}=    RW.CLI.Run Cli
    ...    cmd=rm -f kv_expiry_issues.json

Check Key Vault Logs for Issues in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Check Key Vault log issues
    [Tags]    KeyVault    Azure    Logs    access:read-only
    ${cmd}=    RW.CLI.Run Bash File
    ...    bash_file=log.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    TRY
        ${log_data}=    Evaluate    json.load(open('${CODEBUNDLE_TEMP_DIR}/kv_log_issues.json'))    json
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
            ...    expected=No issues should be found in Key Vault logs in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
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

Check Key Vault Performance Metrics in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Check Key Vault performance metrics for excessive requests and high latency
    [Tags]    KeyVault    Azure    Metrics    access:read-only
    ${cmd}=    RW.CLI.Run Bash File
    ...    bash_file=performance_metrics.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    TRY
        ${metrics_data}=    Evaluate    json.load(open('${CODEBUNDLE_TEMP_DIR}/azure_keyvault_performance_metrics.json'))    json
    EXCEPT
        Log    Failed to load JSON file, defaulting to empty list.    WARN
        ${metrics_data}=    Create Dictionary    issues=[]
    END

    IF    len(${metrics_data['issues']}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["KeyVault", "Metric", "Value", "Threshold", "Resource URL"], (.issues[] | [.name, .metric, .value, .threshold, .resource_url]) | @tsv' azure_keyvault_performance_metrics.json | column -t
        RW.Core.Add Pre To Report    Key Vault Performance Metrics Issues:\n==========================================\n${formatted_results.stdout}

        FOR    ${issue}    IN    @{metrics_data['issues']}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${issue['reproduce_hint']}
            ...    next_steps=${issue['next_step']}
            ...    details=${issue['details']}
        END
    ELSE
        RW.Core.Add Pre To Report    "No performance issues found in Key Vaults in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`"
    END

    ${remove_file}=    RW.CLI.Run Cli
    ...    cmd=rm -f azure_keyvault_performance_metrics.json

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
    ${REQUEST_THRESHOLD}=    RW.Core.Import User Variable    REQUEST_THRESHOLD
    ...    type=integer
    ...    description=Threshold for excessive requests (requests/hour)
    ...    default=1000
    ...    example=1000
    ${LATENCY_THRESHOLD}=    RW.Core.Import User Variable    LATENCY_THRESHOLD
    ...    type=integer
    ...    description=Threshold for high latency (milliseconds)
    ...    default=500
    ...    example=500
    ${REQUEST_INTERVAL}=    RW.Core.Import User Variable    REQUEST_INTERVAL
    ...    type=string
    ...    description=Interval for request count metrics (format: PT1H, PT30M, PT5M, etc.)
    ...    default=PT1H
    ...    example=PT1M
    ${LATENCY_INTERVAL}=    RW.Core.Import User Variable    LATENCY_INTERVAL
    ...    type=string
    ...    description=Interval for latency metrics (format: PT1H, PT30M, PT5M, etc.)
    ...    default=PT1H
    ...    example=PT5M
    ${TIME_RANGE}=    RW.Core.Import User Variable    TIME_RANGE
    ...    type=integer
    ...    description=Time range in hours to look back for metrics
    ...    default=24
    ...    example=24
    ${LOG_QUERY_DAYS}=    RW.Core.Import User Variable    LOG_QUERY_DAYS
    ...    type=string
    ...    description=Time range for log queries (format: 1d, 7d, 30d, etc.)
    ...    default=1d
    ...    example=2d
    Set Suite Variable    ${AZURE_SUBSCRIPTION_NAME}    ${AZURE_SUBSCRIPTION_NAME}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${THRESHOLD_DAYS}    ${THRESHOLD_DAYS}
    Set Suite Variable    ${REQUEST_THRESHOLD}    ${REQUEST_THRESHOLD}
    Set Suite Variable    ${LATENCY_THRESHOLD}    ${LATENCY_THRESHOLD}
    Set Suite Variable    ${REQUEST_INTERVAL}    ${REQUEST_INTERVAL}
    Set Suite Variable    ${LATENCY_INTERVAL}    ${LATENCY_INTERVAL}
    Set Suite Variable    ${TIME_RANGE}    ${TIME_RANGE}
    Set Suite Variable    ${LOG_QUERY_DAYS}    ${LOG_QUERY_DAYS}
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}", "AZURE_SUBSCRIPTION_NAME":"${AZURE_SUBSCRIPTION_NAME}", "THRESHOLD_DAYS":"${THRESHOLD_DAYS}", "REQUEST_THRESHOLD":"${REQUEST_THRESHOLD}", "LATENCY_THRESHOLD":"${LATENCY_THRESHOLD}", "REQUEST_INTERVAL":"${REQUEST_INTERVAL}", "LATENCY_INTERVAL":"${LATENCY_INTERVAL}", "TIME_RANGE":"${TIME_RANGE}", "LOG_QUERY_DAYS":"${LOG_QUERY_DAYS}"}