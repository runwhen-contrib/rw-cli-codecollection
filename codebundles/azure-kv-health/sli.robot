*** Settings ***
Documentation       Counts Azure Key Vault health by checking availability metrics, configuration settings, expiring items (secrets/certificates/keys), log issues, and performance metrics
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
Count Key Vault Resource Health in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Counts the health status of Key Vaults in the specified resource group
    [Tags]    KeyVault    Azure    Health    access:read-only
    ${resource_health}=    RW.CLI.Run Bash File
    ...    bash_file=kv_resource_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(open('${CODEBUNDLE_TEMP_DIR}/keyvault_health.json').read())    json
    EXCEPT
        Log    Failed to load JSON file, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    ${issue_count}=    Set Variable    0
    FOR    ${kv_health}    IN    @{issue_list}
        IF    "${kv_health['properties']['title']}" != "Available"
            ${issue_count}=    Evaluate    ${issue_count} + 1
        END
    END

    ${kv_resource_health_score}=    Evaluate    1 if ${issue_count} == 0 else 0
    Set Global Variable    ${kv_resource_health_score}

Count Key Vault Availability in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Counts number of Azure key vault vaults with availability below 100% 
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

    ${issue_count}=    Set Variable    0
    FOR    ${metric}    IN    @{availability_data['metrics']}
        IF    '${metric['percentage']}' != 'N/A' and float(${metric['percentage']}) < 100
            ${issue_count}=    Evaluate    ${issue_count} + 1
        END
    END

    ${kv_availability_score}=    Evaluate    1 if ${issue_count} == 0 else 0
    Set Global Variable    ${kv_availability_score}

Count Key Vault configuration in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Count Key vault's miss-configuration
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

    ${issue_count}=    Set Variable    0
    FOR    ${kv}    IN    @{config_data['keyVaults']}
        IF    '${kv['soft_delete']}' != 'true' or '${kv['purge_protection']}' != 'true'
            ${issue_count}=    Evaluate    ${issue_count} + 1
        END
    END

    ${kv_config_score}=    Evaluate    1 if ${issue_count} == 0 else 0
    Set Global Variable    ${kv_config_score}

Count Expiring Key Vault Items in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Count expiring secrets, certificates, and keys in Key Vaults
    [Tags]    KeyVault    Azure    Expiry    access:read-only

    # Run expiry checks script which generates kv_expiry_issues.json
    ${expiry_output}=    RW.CLI.Run Bash File
    ...    bash_file=expiry-checks.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    TRY
        ${expiry_data}=    Evaluate    json.load(open('${CODEBUNDLE_TEMP_DIR}/kv_expiry_issues.json'))    json
    EXCEPT
        Log    Failed to load JSON file, defaulting to empty list.    WARN
        ${expiry_data}=    Create Dictionary    issues=[]
    END

    ${issue_count}=    Set Variable    len(${expiry_data['issues']})
    ${kv_expiry_score}=    Evaluate    1 if ${issue_count} == 0 else 0
    ${remove_file}=    RW.CLI.Run Cli
    ...    cmd=rm -f kv_expiry_issues.json
    Set Global Variable    ${kv_expiry_score}

Count Key Vault Log Issues in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Count Key Vault log issues
    [Tags]    KeyVault    Azure    Logs    access:read-only
    ${cmd}=    RW.CLI.Run Bash File
    ...    bash_file=log.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false

    TRY
        ${log_data}=    Evaluate    json.load(open('${CODEBUNDLE_TEMP_DIR}/kv_log_issues.json'))    json
    EXCEPT
        Log    Failed to load JSON file, defaulting to empty list.    WARN
        ${log_data}=    Create Dictionary    issues=[]
    END

    ${issue_count}=    Set Variable    len(${log_data['issues']})
    ${kv_log_score}=    Evaluate    1 if ${issue_count} == 0 else 0
    ${remove_file}=    RW.CLI.Run Cli
    ...    cmd=rm -f kv_log_issues.json
    Set Global Variable    ${kv_log_score}

Count Key Vault Performance Metrics in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Count Key Vault performance metrics issues
    [Tags]    KeyVault    Azure    Metrics    access:read-only
    ${cmd}=    RW.CLI.Run Bash File
    ...    bash_file=performance_metrics.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false

    TRY
        ${metrics_data}=    Evaluate    json.load(open('${CODEBUNDLE_TEMP_DIR}/azure_keyvault_performance_metrics.json'))    json
    EXCEPT
        Log    Failed to load JSON file, defaulting to empty list.    WARN
        ${metrics_data}=    Create Dictionary    issues=[]
    END

    ${issue_count}=    Set Variable    len(${metrics_data['issues']})
    ${kv_perf_score}=    Evaluate    1 if ${issue_count} == 0 else 0
    ${remove_file}=    RW.CLI.Run Cli
    ...    cmd=rm -f azure_keyvault_performance_metrics.json
    Set Global Variable    ${kv_perf_score}

Generate Comprehensive Key Vault Health Score
    ${kv_health_score}=    Evaluate    (${kv_availability_score} + ${kv_config_score} + ${kv_expiry_score} + ${kv_log_score} + ${kv_perf_score}) / 5
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