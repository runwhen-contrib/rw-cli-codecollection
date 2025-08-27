*** Settings ***
Documentation       Comprehensive health checks for Azure Container Registry (ACR), including network configuration, resource health, authentication, storage utilization, pull/push metrics, and security analysis.
Metadata            Author    Nbarola
Metadata            Display Name    Azure ACR Health Check
Metadata            Supports    Azure    Container Registry    ACR    Health    Network    Security    Storage

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             String
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***


Check Network Configuration for ACR `${ACR_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Analyze network access rules, private endpoints, firewall settings, and connectivity.
    [Tags]    access:read-only    ACR    Azure    Network    Security    Connectivity
    ${network_config}=    RW.CLI.Run Bash File
    ...    bash_file=acr_network_config.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${network_config.stderr}
    
    # Add portal URL for Network configuration
    ${acr_resource_id_network}=    RW.CLI.Run Cli
    ...    cmd=az acr show --name "${ACR_NAME}" --resource-group "${AZ_RESOURCE_GROUP}" --query "id" -o tsv
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    ${network_url}=    Set Variable    https://portal.azure.com/#@/resource${acr_resource_id_network.stdout.strip()}/networking
    RW.Core.Add Pre To Report    🔗 View Network Configuration in Azure Portal: ${network_url}

    ${issues}=    Evaluate    json.loads(r'''${network_config.stdout}''')    json
    IF    len(@{issues}) > 0
        FOR    ${issue}    IN    @{issues}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    title=${issue["title"]}
            ...    expected=${issue["expected"]}
            ...    actual=${issue["actual"]}
            ...    reproduce_hint=${issue.get("reproduce_hint", "")}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_steps"]}
        END
    END

Check DNS & TLS Reachability for Registry `${ACR_NAME}`
    [Documentation]    Verifies DNS resolution and HTTPS/TLS for ACR endpoint.
    [Tags]    access:read-only    ACR    Azure    DNS    TLS    Connectivity    Health
    ${dns_tls}=    RW.CLI.Run Bash File
    ...    bash_file=acr_reachability.sh
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${dns_tls.stderr}
    
    ${issues}=    Evaluate    json.loads(r'''${dns_tls.stdout}''')    json
    IF    len(@{issues}) > 0
        FOR    ${issue}    IN    @{issues}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    title=${issue["title"]}
            ...    expected=${issue["expected"]}
            ...    actual=${issue["actual"]}
            ...    reproduce_hint=${issue.get("reproduce_hint", "")}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_steps"]}
        END
    END

Check ACR Login & Authentication for Registry `${ACR_NAME}`
    [Documentation]    Attempts az acr login and docker login using intended workload identity.
    [Tags]    access:read-only    ACR    Azure    Login    Auth    Connectivity    Health
    ${login}=    RW.CLI.Run Bash File
    ...    bash_file=acr_authentication.sh
    ...    env=${env}
    ...    timeout_seconds=90
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${login.stderr}
    
    # Add portal URL for Access Keys
    ${acr_resource_id_auth}=    RW.CLI.Run Cli
    ...    cmd=az acr show --name "${ACR_NAME}" --resource-group "${AZ_RESOURCE_GROUP}" --query "id" -o tsv
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    ${auth_url}=    Set Variable    https://portal.azure.com/#@/resource${acr_resource_id_auth.stdout.strip()}/accessKey
    RW.Core.Add Pre To Report    🔗 View Access Keys in Azure Portal: ${auth_url}

    ${issues}=    Evaluate    json.loads(r'''${login.stdout}''')    json
    IF    len(@{issues}) > 0
        FOR    ${issue}    IN    @{issues}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    title=${issue["title"]}
            ...    expected=${issue["expected"]}
            ...    actual=${issue["actual"]}
            ...    reproduce_hint=${issue.get("reproduce_hint", "")}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_steps"]}
        END
    END

Check ACR SKU and Usage Metrics for Registry `${ACR_NAME}`
    [Documentation]    Analyzes ACR SKU configuration, usage limits, and provides recommendations.
    [Tags]    access:read-only    ACR    Azure    SKU    Usage    Health
    ${sku_usage}=    RW.CLI.Run Bash File
    ...    bash_file=acr_usage_sku.sh
    ...    env=${env}
    ...    timeout_seconds=120
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${sku_usage.stderr}
    
    # Add portal URL for Usage
    ${acr_resource_id_usage}=    RW.CLI.Run Cli
    ...    cmd=az acr show --name "${ACR_NAME}" --resource-group "${AZ_RESOURCE_GROUP}" --query "id" -o tsv
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    ${usage_url}=    Set Variable    https://portal.azure.com/#@/resource${acr_resource_id_usage.stdout.strip()}/usage
    RW.Core.Add Pre To Report    🔗 View Usage in Azure Portal: ${usage_url}

    ${issues}=    Evaluate    json.loads(r'''${sku_usage.stdout}''')    json
    IF    len(@{issues}) > 0
        FOR    ${issue}    IN    @{issues}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    title=${issue["title"]}
            ...    expected=${issue["expected"]}
            ...    actual=${issue["actual"]}
            ...    reproduce_hint=${issue.get("reproduce_hint", "")}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_steps"]}
        END
    END

Check ACR Storage Utilization for Registry `${ACR_NAME}`
    [Documentation]    Comprehensive analysis of ACR storage usage, repository sizes, and cleanup recommendations.
    [Tags]    access:read-only    ACR    Azure    Storage    Utilization    Health
    ${storage_util}=    RW.CLI.Run Bash File
    ...    bash_file=acr_storage_utilization.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${storage_util.stderr}
    
    # Add portal URLs for Storage management
    ${acr_resource_id_storage}=    RW.CLI.Run Cli
    ...    cmd=az acr show --name "${ACR_NAME}" --resource-group "${AZ_RESOURCE_GROUP}" --query "id" -o tsv
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    ${repositories_url}=    Set Variable    https://portal.azure.com/#@/resource${acr_resource_id_storage.stdout.strip()}/repositories
    ${retention_url}=    Set Variable    https://portal.azure.com/#@/resource${acr_resource_id_storage.stdout.strip()}/retentionPolicies
    RW.Core.Add Pre To Report    🔗 View Repositories in Azure Portal: ${repositories_url}
    RW.Core.Add Pre To Report    🔗 Configure Retention Policies: ${retention_url}

    ${issues}=    Evaluate    json.loads(r'''${storage_util.stdout}''')    json
    IF    len(@{issues}) > 0
        FOR    ${issue}    IN    @{issues}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    title=${issue["title"]}
            ...    expected=${issue["expected"]}
            ...    actual=${issue["actual"]}
            ...    reproduce_hint=${issue.get("reproduce_hint", "")}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_steps"]}
        END
    END

Analyze ACR Pull/Push Success Ratio for Registry `${ACR_NAME}`
    [Documentation]    Analyzes pull and push operation success rates using Azure Monitor metrics and Log Analytics.
    [Tags]    access:read-only    ACR    Azure    Pull    Push    Metrics    Health
    ${pull_push_ratio}=    RW.CLI.Run Bash File
    ...    bash_file=acr_pull_push_ratio.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${pull_push_ratio.stderr}
    
    # Add portal URLs for Metrics and Logs
    ${acr_resource_id_metrics}=    RW.CLI.Run Cli
    ...    cmd=az acr show --name "${ACR_NAME}" --resource-group "${AZ_RESOURCE_GROUP}" --query "id" -o tsv
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    ${metrics_url}=    Set Variable    https://portal.azure.com/#@/resource${acr_resource_id_metrics.stdout.strip()}/metrics
    ${logs_url}=    Set Variable    https://portal.azure.com/#@/resource${acr_resource_id_metrics.stdout.strip()}/logs
    RW.Core.Add Pre To Report    🔗 View Metrics in Azure Portal: ${metrics_url}
    RW.Core.Add Pre To Report    🔗 View Logs in Azure Portal: ${logs_url}

    ${issues}=    Evaluate    json.loads(r'''${pull_push_ratio.stdout}''')    json
    IF    len(@{issues}) > 0
        FOR    ${issue}    IN    @{issues}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    title=${issue["title"]}
            ...    expected=${issue["expected"]}
            ...    actual=${issue["actual"]}
            ...    reproduce_hint=${issue.get("reproduce_hint", "")}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_steps"]}
        END
    END


Check ACR Repository Event Failures for Registry `${ACR_NAME}`
    [Documentation]    Queries Log Analytics for recent failed pushes/pulls and repo errors.
    [Tags]    access:read-only    ACR    Azure    Events    Health
    ${repo_events}=    RW.CLI.Run Bash File
    ...    bash_file=acr_events.sh
    ...    env=${env}
    ...    timeout_seconds=90
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${repo_events.stderr}
    
    ${issues}=    Evaluate    json.loads(r'''${repo_events.stdout}''')    json
    IF    len(@{issues}) > 0
        FOR    ${issue}    IN    @{issues}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    title=${issue["title"]}
            ...    expected=${issue["expected"]}
            ...    actual=${issue["actual"]}
            ...    reproduce_hint=${issue.get("reproduce_hint", "")}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_steps"]}
        END
    END

Check ACR Security Configuration and RBAC for Registry `${ACR_NAME}`
    [Documentation]    Comprehensive security analysis of ACR including RBAC assignments, admin user status,
    ...    network access rules, private endpoints, and authentication methods. Identifies security
    ...    misconfigurations and provides recommendations for hardening the registry.
    [Tags]    acr    security    rbac    authentication    network
    ${security_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=acr_rbac_security.sh
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    # Add diagnostic information to the report
    RW.Core.Add Pre To Report    ${security_analysis.stderr}
    
    # Generate portal URLs for security management
    ${acr_resource_id_security}=    RW.CLI.Run Cli
    ...    cmd=az acr show --name "${ACR_NAME}" --resource-group "${AZ_RESOURCE_GROUP}" --query "id" -o tsv
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    
    ${security_url}=    Set Variable    https://portal.azure.com/#@/resource${acr_resource_id_security.stdout.strip()}/users
    ${networking_url}=    Set Variable    https://portal.azure.com/#@/resource${acr_resource_id_security.stdout.strip()}/networking
    ${webhooks_url}=    Set Variable    https://portal.azure.com/#@/resource${acr_resource_id_security.stdout.strip()}/webhooks
    
    RW.Core.Add Pre To Report    🔗 View Access Control (IAM): ${security_url}
    RW.Core.Add Pre To Report    🔗 Configure Networking: ${networking_url}
    RW.Core.Add Pre To Report    🔗 Manage Webhooks: ${webhooks_url}

    # Parse and process security issues
    ${issues}=    Evaluate    json.loads(r'''${security_analysis.stdout}''')    json
    FOR    ${issue}    IN    @{issues}
        RW.Core.Add Issue
        ...    severity=${issue["severity"]}
        ...    title=${issue["title"]}
        ...    expected=${issue["expected"]}
        ...    actual=${issue["actual"]}
        ...    reproduce_hint=${issue["reproduce_hint"]}
        ...    details=${issue["details"]}
        ...    next_steps=${issue["next_steps"]}
    END


*** Keywords ***
Suite Initialization
    ${AZ_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZ_RESOURCE_GROUP
    ...    type=string
    ...    description=The resource group containing the ACR.
    ...    pattern=\w*
    ${ACR_NAME}=    RW.Core.Import User Variable    ACR_NAME
    ...    type=string
    ...    description=Azure Container Registry Name.
    ...    pattern=^[a-zA-Z0-9]*$
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    ${AZURE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure Subscription ID.
    ...    pattern=\w*
    ${AZURE_SUBSCRIPTION_NAME}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_NAME
    ...    type=string
    ...    description=The Azure Subscription Name.
    ...    pattern=\w*

    ${USAGE_THRESHOLD}=    RW.Core.Import User Variable    USAGE_THRESHOLD
    ...     type=string
    ...     description=Threshold for acr usage
    ...    pattern=\d*
    ...    default=80
    Set Suite Variable    ${ACR_NAME}    ${ACR_NAME}
    Set Suite Variable    ${azure_credentials}    ${azure_credentials}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_NAME}    ${AZURE_SUBSCRIPTION_NAME}
    Set Suite Variable
    ...    ${env}
    ...    {"ACR_NAME": "${ACR_NAME}", "AZ_RESOURCE_GROUP": "${AZ_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID": "${AZURE_SUBSCRIPTION_ID}", "AZURE_SUBSCRIPTION_NAME": "${AZURE_SUBSCRIPTION_NAME}", "USAGE_THRESHOLD": "${USAGE_THRESHOLD}"}
    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZURE_SUBSCRIPTION_ID}
    ...    include_in_history=false
