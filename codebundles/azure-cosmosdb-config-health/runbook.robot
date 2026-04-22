*** Settings ***
Documentation       Validates Azure Cosmos DB account configuration for availability, security, recoverability, and operability using read-only Azure Resource Manager and monitoring APIs.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Azure Cosmos DB Configuration Health
Metadata            Supports    Azure    Cosmos DB    Configuration    Health
Force Tags          Azure    Cosmos DB    Configuration    Health

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check Cosmos DB Resource Health for Account `${COSMOSDB_ACCOUNT_NAME}` in Resource Group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Uses Azure Resource Health to detect platform incidents or account-level availability problems for the scoped Cosmos DB account(s).
    [Tags]    Azure    CosmosDB    ResourceHealth    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=cosmosdb-resource-health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./cosmosdb-resource-health.sh
    RW.Core.Add Pre To Report    ${result.stdout}
    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat cosmosdb_resource_health_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for resource health task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Cosmos DB should report Available in Azure Resource Health for accounts in `${AZURE_RESOURCE_GROUP}`
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Check Cosmos DB API and Consistency Configuration for Account `${COSMOSDB_ACCOUNT_NAME}` in Resource Group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Reviews default consistency, multi-region writes, and metadata write protection against common production baselines.
    [Tags]    Azure    CosmosDB    Consistency    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=cosmosdb-api-consistency-config.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=./cosmosdb-api-consistency-config.sh
    RW.Core.Add Pre To Report    ${result.stdout}
    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat cosmosdb_api_consistency_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for API consistency task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Cosmos DB API settings should align with workload consistency and security baselines
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Check Cosmos DB Backup and Point-in-Time Settings for Account `${COSMOSDB_ACCOUNT_NAME}` in Resource Group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Verifies periodic or continuous backup configuration and retention suitability for recovery objectives.
    [Tags]    Azure    CosmosDB    Backup    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=cosmosdb-backup-policy.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=./cosmosdb-backup-policy.sh
    RW.Core.Add Pre To Report    ${result.stdout}
    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat cosmosdb_backup_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for backup policy task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Backup policy should provide adequate retention and a supported backup mode
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Check Cosmos DB Public Network Access and Firewall Rules for Account `${COSMOSDB_ACCOUNT_NAME}` in Resource Group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Flags public exposure or overly permissive IP rules that conflict with zero-trust network patterns.
    [Tags]    Azure    CosmosDB    Networking    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=cosmosdb-network-firewall.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=./cosmosdb-network-firewall.sh
    RW.Core.Add Pre To Report    ${result.stdout}
    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat cosmosdb_network_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for network task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Network access should be restricted with private endpoints or explicit IP/VNet controls
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Check Cosmos DB Private Endpoint Configuration for Account `${COSMOSDB_ACCOUNT_NAME}` in Resource Group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Validates private link setup and connection approval when public network access is disabled.
    [Tags]    Azure    CosmosDB    PrivateLink    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=cosmosdb-private-endpoints.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=./cosmosdb-private-endpoints.sh
    RW.Core.Add Pre To Report    ${result.stdout}
    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat cosmosdb_private_endpoint_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for private endpoint task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Private endpoints should exist and be Approved when public access is disabled
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Check Cosmos DB Diagnostic Settings for Account `${COSMOSDB_ACCOUNT_NAME}` in Resource Group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Ensures metrics and logs are exported to Log Analytics, storage, or Event Hubs for troubleshooting and audit.
    [Tags]    Azure    CosmosDB    Diagnostics    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=cosmosdb-diagnostic-settings.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=./cosmosdb-diagnostic-settings.sh
    RW.Core.Add Pre To Report    ${result.stdout}
    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat cosmosdb_diagnostic_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for diagnostic settings task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=At least one diagnostic setting should stream Cosmos DB platform telemetry
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Check Cosmos DB Activity Log for Recent Configuration Changes to Account `${COSMOSDB_ACCOUNT_NAME}` in Resource Group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Surfaces recent administrative mutations that may explain throughput, failover, networking, or backup behavior changes.
    [Tags]    Azure    CosmosDB    ActivityLog    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=cosmosdb-activity-changes.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=./cosmosdb-activity-changes.sh
    RW.Core.Add Pre To Report    ${result.stdout}
    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat cosmosdb_activity_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for activity log task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Activity log should be reviewed when investigating unexpected Cosmos DB behavior
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END


*** Keywords ***
Suite Initialization
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=JSON or env-style secret with Azure service principal fields used by Azure CLI login patterns in this workspace.
    ...    pattern=\w*
    ${AZ_SUBSCRIPTION}=    RW.Core.Import User Variable    AZ_SUBSCRIPTION
    ...    type=string
    ...    description=Azure subscription ID (UUID) containing the Cosmos DB account.
    ...    pattern=[a-fA-F0-9-]{36}
    ${AZURE_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZURE_RESOURCE_GROUP
    ...    type=string
    ...    description=Resource group containing the Cosmos DB account(s).
    ...    pattern=\w*
    ${COSMOSDB_ACCOUNT_NAME}=    RW.Core.Import User Variable    COSMOSDB_ACCOUNT_NAME
    ...    type=string
    ...    description=Cosmos DB account name, or All to scan every account in the resource group.
    ...    default=All
    ...    pattern=\w*
    ${ACTIVITY_LOG_LOOKBACK_HOURS}=    RW.Core.Import User Variable    ACTIVITY_LOG_LOOKBACK_HOURS
    ...    type=string
    ...    description=Hours of activity log history to scan for administrative events.
    ...    default=168
    ...    pattern=^\d+$
    Set Suite Variable    ${AZ_SUBSCRIPTION}    ${AZ_SUBSCRIPTION}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${COSMOSDB_ACCOUNT_NAME}    ${COSMOSDB_ACCOUNT_NAME}
    Set Suite Variable    ${ACTIVITY_LOG_LOOKBACK_HOURS}    ${ACTIVITY_LOG_LOOKBACK_HOURS}
    Set Suite Variable
    ...    ${env}
    ...    {"AZ_SUBSCRIPTION":"${AZ_SUBSCRIPTION}", "AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "COSMOSDB_ACCOUNT_NAME":"${COSMOSDB_ACCOUNT_NAME}", "ACTIVITY_LOG_LOOKBACK_HOURS":"${ACTIVITY_LOG_LOOKBACK_HOURS}"}
    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZ_SUBSCRIPTION}
    ...    include_in_history=false
