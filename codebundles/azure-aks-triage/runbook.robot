*** Settings ***
Documentation       Runs diagnostic checks against an AKS cluster.
Metadata            Author    stewartshea
Metadata            Display Name    Azure AKS Triage
Metadata            Supports    Azure    AKS    Kubernetes    Service    Triage    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             DateTime

Suite Setup         Suite Initialization


*** Tasks ***
Check for Resource Health Issues Affecting AKS Cluster `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch a list of issues that might affect the AKS cluster
    [Tags]    aks    config    access:read-only
    ${resource_health}=    RW.CLI.Run Bash File
    ...    bash_file=aks_resource_health.sh
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    # Check for timeout or authentication failures
    IF    ${resource_health.returncode} == -1
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Azure resource health check should complete within timeout for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    actual=Azure resource health check timed out after 60 seconds for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    title=Azure Resource Health Check Timeout for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    reproduce_hint=${resource_health.cmd}
        ...    details=Command timed out after 60 seconds. This may indicate authentication issues, network connectivity problems, or Azure service delays.
        ...    next_steps=Check Azure authentication with 'az account show'\nVerify network connectivity to Azure services\nCheck if Azure service principal credentials are expired\nTry running the command manually: ${resource_health.cmd}
        RETURN
    END
    
    # Check for authentication failures in output
    ${auth_failed}=    Run Keyword And Return Status    Should Contain    ${resource_health.stdout}    Authentication failed
    ${token_expired}=    Run Keyword And Return Status    Should Contain    ${resource_health.stdout}    client secret keys
    ${login_failed}=    Run Keyword And Return Status    Should Contain    ${resource_health.stdout}    Azure login failed
    IF    ${auth_failed} or ${token_expired} or ${login_failed}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Azure authentication should succeed for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    actual=Azure authentication failed for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    title=Azure Authentication Failed for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    reproduce_hint=${resource_health.cmd}
        ...    details=${resource_health.stdout}
        ...    next_steps=Check Azure service principal credentials are not expired\nRenew client secret in Azure portal: https://aka.ms/NewClientSecret\nVerify tenant ID and client ID are correct\nTest authentication with: az login --service-principal --username <client-id> --password <client-secret> --tenant <tenant-id>
        RETURN
    END
    
    RW.Core.Add Pre To Report    ${resource_health.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat az_resource_health.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    ${timestamp}=    DateTime.Get Current Date
    IF    len(@{issue_list}) > 0 
        IF    "${issue_list["properties"]["title"]}" != "Available"
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=Azure resources should be available for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
            ...    actual=Azure resources are unhealthy for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
            ...    title=Azure reports an `${issue_list["properties"]["title"]}` Issue for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
            ...    reproduce_hint=${resource_health.cmd}
            ...    details=${issue_list}
            ...    next_steps=Please escalate to the Azure service owner or check back later.
            ...    observed_at=${issue_list["properties"]["occuredTime"]}
        END
    ELSE
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Azure resources health should be enabled for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    actual=Azure resource health appears unavailable for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    title=Azure resource health is unavailable for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    reproduce_hint=${resource_health.cmd}
        ...    details=${issue_list}
        ...    next_steps=Please escalate to the Azure service owner to enable provider Microsoft.ResourceHealth.
        ...    observed_at=${timestamp}
    END


Check Configuration Health of AKS Cluster `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch the config of the AKS cluster in azure
    [Tags]    AKS    config   access:read-only
    ${config}=    RW.CLI.Run Bash File
    ...    bash_file=aks_cluster_health.sh
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    # Check for timeout or authentication failures
    IF    ${config.returncode} == -1
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=AKS cluster configuration check should complete within timeout for `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    actual=AKS cluster configuration check timed out after 60 seconds for `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    title=AKS Configuration Check Timeout for Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    reproduce_hint=${config.cmd}
        ...    details=Command timed out after 60 seconds. This may indicate authentication issues, network connectivity problems, or Azure service delays.
        ...    next_steps=Check Azure authentication with 'az account show'\nVerify network connectivity to Azure services\nCheck if Azure service principal credentials are expired\nTry running the command manually: ${config.cmd}
        RETURN
    END
    
    # Check for authentication failures in output
    ${auth_failed}=    Run Keyword And Return Status    Should Contain    ${config.stdout}    Authentication failed
    ${token_expired}=    Run Keyword And Return Status    Should Contain    ${config.stdout}    client secret keys
    ${login_failed}=    Run Keyword And Return Status    Should Contain    ${config.stdout}    Azure login failed
    IF    ${auth_failed} or ${token_expired} or ${login_failed}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Azure authentication should succeed for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    actual=Azure authentication failed for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    title=Azure Authentication Failed for AKS Configuration Check of `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    reproduce_hint=${config.cmd}
        ...    details=${config.stdout}
        ...    next_steps=Check Azure service principal credentials are not expired\nRenew client secret in Azure portal: https://aka.ms/NewClientSecret\nVerify tenant ID and client ID are correct\nTest authentication with: az login --service-principal --username <client-id> --password <client-secret> --tenant <tenant-id>
        RETURN
    END
    
    RW.Core.Add Pre To Report    ${config.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat az_cluster_health.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    ${timestamp}=    DateTime.Get Current Date
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=AKS Cluster `${AKS_CLUSTER}` in resource group `${AZ_RESOURCE_GROUP}` has no configuration issues
            ...    actual=AKS Cluster `${AKS_CLUSTER}` in resource group `${AZ_RESOURCE_GROUP}` has configuration issues
            ...    reproduce_hint=${config.cmd}
            ...    details=${item["details"]}        
            ...    observed_at=${timestamp}
        END
    END
Check Network Configuration of AKS Cluster `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}`
   [Documentation]    Fetch the network configuration, generating resource URLs and basic recommendations
   [Tags]    AKS    config    network    route    firewall    access:read-only
   ${network}=    RW.CLI.Run Bash File
   ...    bash_file=aks_network.sh
   ...    env=${env}
   ...    timeout_seconds=120
   ...    include_in_history=false
   ...    show_in_rwl_cheatsheet=true
   
   # Check for timeout or authentication failures
   IF    ${network.returncode} == -1
       RW.Core.Add Issue
       ...    severity=2
       ...    expected=AKS network configuration check should complete within timeout for `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
       ...    actual=AKS network configuration check timed out after 120 seconds for `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
       ...    title=AKS Network Configuration Check Timeout for Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
       ...    reproduce_hint=${network.cmd}
       ...    details=Command timed out after 120 seconds. This may indicate authentication issues, network connectivity problems, or Azure service delays.
       ...    next_steps=Check Azure authentication with 'az account show'\nVerify network connectivity to Azure services\nCheck if Azure service principal credentials are expired\nTry running the command manually: ${network.cmd}
       RETURN
   END
   
   # Check for authentication failures in output
   ${auth_failed}=    Run Keyword And Return Status    Should Contain    ${network.stdout}    Authentication failed
   ${token_expired}=    Run Keyword And Return Status    Should Contain    ${network.stdout}    client secret keys
   ${login_failed}=    Run Keyword And Return Status    Should Contain    ${network.stdout}    Azure login failed
   IF    ${auth_failed} or ${token_expired} or ${login_failed}
       RW.Core.Add Issue
       ...    severity=2
       ...    expected=Azure authentication should succeed for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
       ...    actual=Azure authentication failed for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
       ...    title=Azure Authentication Failed for AKS Network Configuration Check of `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
       ...    reproduce_hint=${network.cmd}
       ...    details=${network.stdout}
       ...    next_steps=Check Azure service principal credentials are not expired\nRenew client secret in Azure portal: https://aka.ms/NewClientSecret\nVerify tenant ID and client ID are correct\nTest authentication with: az login --service-principal --username <client-id> --password <client-secret> --tenant <tenant-id>
       RETURN
   END
   
   RW.Core.Add Pre To Report    ${network.stdout}

Fetch Activities for AKS Cluster `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Gets the activities for the AKS cluster set and checks for errors
    [Tags]    AKS    activities    monitor    events    errors    access:read-only
    ${activites}=    RW.CLI.Run Bash File
    ...    bash_file=aks_activities.sh
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    
    # Check for timeout or authentication failures
    IF    ${activites.returncode} == -1
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=AKS activities check should complete within timeout for `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    actual=AKS activities check timed out after 60 seconds for `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    title=AKS Activities Check Timeout for Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    reproduce_hint=${activites.cmd}
        ...    details=Command timed out after 60 seconds. This may indicate authentication issues, network connectivity problems, or Azure service delays.
        ...    next_steps=Check Azure authentication with 'az account show'\nVerify network connectivity to Azure services\nCheck if Azure service principal credentials are expired\nTry running the command manually: ${activites.cmd}
        RETURN
    END
    
    # Check for authentication failures in output
    ${auth_failed}=    Run Keyword And Return Status    Should Contain    ${activites.stdout}    Authentication failed
    ${token_expired}=    Run Keyword And Return Status    Should Contain    ${activites.stdout}    client secret keys
    ${login_failed}=    Run Keyword And Return Status    Should Contain    ${activites.stdout}    Azure login failed
    IF    ${auth_failed} or ${token_expired} or ${login_failed}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Azure authentication should succeed for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    actual=Azure authentication failed for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    title=Azure Authentication Failed for AKS Activities Check of `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    reproduce_hint=${activites.cmd}
        ...    details=${activites.stdout}
        ...    next_steps=Check Azure service principal credentials are not expired\nRenew client secret in Azure portal: https://aka.ms/NewClientSecret\nVerify tenant ID and client ID are correct\nTest authentication with: az login --service-principal --username <client-id> --password <client-secret> --tenant <tenant-id>
        RETURN
    END

    RW.Core.Add Pre To Report    ${activites.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat aks_activities_issues.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=AKS Cluster `${AKS_CLUSTER}` in resource group `${AZ_RESOURCE_GROUP}` has no Warning/Error/Critical activities
            ...    actual=AKS Cluster `${AKS_CLUSTER}` in resource group `${AZ_RESOURCE_GROUP}` has Warning/Error/Critical activities
            ...    reproduce_hint=${activites.cmd}
            ...    details=${item["details"]}        
            ...    observed_at=${item["observed_at"]}
        END
    END

Analyze AKS Cluster Cost Optimization Opportunities for `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Analyzes 30-day utilization trends using Azure Monitor to identify underutilized node pools with cost savings opportunities. Provides Azure VM pricing-based estimates for potential monthly and annual savings with severity bands: Sev4 <$2k/month, Sev3 $2k-$10k/month, Sev2 >$10k/month.
    [Tags]    aks    cost-optimization    underutilization    azure-monitor    pricing    access:read-only
    ${cost_optimization}=    RW.CLI.Run Bash File
    ...    bash_file=aks_cost_optimization.sh
    ...    env=${env}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    # Check for timeout or authentication failures
    IF    ${cost_optimization.returncode} == -1
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=AKS cost optimization analysis should complete within timeout for `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    actual=AKS cost optimization analysis timed out after 300 seconds for `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    title=AKS Cost Optimization Analysis Timeout for Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    reproduce_hint=${cost_optimization.cmd}
        ...    details=Command timed out after 300 seconds. This may indicate authentication issues, network connectivity problems, or Azure service delays.
        ...    next_steps=Check Azure authentication with 'az account show'\nVerify network connectivity to Azure services\nCheck if Azure service principal credentials are expired\nTry running the command manually: ${cost_optimization.cmd}
        RETURN
    END
    
    # Check for authentication failures in output
    ${auth_failed}=    Run Keyword And Return Status    Should Contain    ${cost_optimization.stdout}    Authentication failed
    ${token_expired}=    Run Keyword And Return Status    Should Contain    ${cost_optimization.stdout}    client secret keys
    ${login_failed}=    Run Keyword And Return Status    Should Contain    ${cost_optimization.stdout}    Azure login failed
    IF    ${auth_failed} or ${token_expired} or ${login_failed}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Azure authentication should succeed for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    actual=Azure authentication failed for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    title=Azure Authentication Failed for AKS Cost Optimization Analysis of `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    reproduce_hint=${cost_optimization.cmd}
        ...    details=${cost_optimization.stdout}
        ...    next_steps=Check Azure service principal credentials are not expired\nRenew client secret in Azure portal: https://aka.ms/NewClientSecret\nVerify tenant ID and client ID are correct\nTest authentication with: az login --service-principal --username <client-id> --password <client-secret> --tenant <tenant-id>
        RETURN
    END
    
    RW.Core.Add Pre To Report    ${cost_optimization.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat aks_cost_optimization_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0 
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=AKS node pools should be efficiently utilized to minimize costs
            ...    actual=AKS node pools show underutilization patterns with cost savings opportunities
            ...    title=${issue["title"]}
            ...    reproduce_hint=${cost_optimization.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_step"]}
        END
    END


*** Keywords ***
Suite Initialization
    ${AZ_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZ_RESOURCE_GROUP
    ...    type=string
    ...    description=The resource group to perform actions against.
    ...    pattern=\w*
    ${AKS_CLUSTER}=    RW.Core.Import User Variable    AKS_CLUSTER
    ...    type=string
    ...    description=The Azure AKS cluster to triage.
    ...    pattern=\w*
    ${RW_LOOKBACK_WINDOW}=    RW.Core.Import User Variable    RW_LOOKBACK_WINDOW
    ...    type=string
    ...    description=The time period, in minutes, to look back for activites/events. 
    ...    pattern=\w*
    ...    default=60
    ${TIMEOUT_SECONDS}=    RW.Core.Import User Variable    TIMEOUT_SECONDS
    ...    type=string
    ...    description=Timeout in seconds for tasks (default: 900).
    ...    pattern=\d+
    ...    default=900
    ${AZURE_RESOURCE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_RESOURCE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure Subscription ID for the resource.  
    ...    pattern=\w*
    ...    default=""
    # Import Azure credentials with error handling
    ${azure_credentials_status}=    Run Keyword And Return Status
    ...    RW.Core.Import Secret    azure_credentials    type=string    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID    pattern=\w*
    
    # Get the actual credentials if import succeeded
    IF    ${azure_credentials_status}
        ${azure_credentials}=    RW.Core.Import Secret
        ...    azure_credentials
        ...    type=string
        ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
        ...    pattern=\w*
    END
    
    # Check if credential import failed
    IF    not ${azure_credentials_status}
        RW.Core.Add Issue
        ...    severity=1
        ...    expected=Azure service principal credentials should be valid and not expired
        ...    actual=Azure service principal authentication failed during suite initialization
        ...    title=Azure Authentication Failed - Service Principal Credentials Expired or Invalid
        ...    reproduce_hint=Check Azure service principal credentials in workspace secrets
        ...    details=Azure authentication failed during suite setup. The service principal client secret may be expired or invalid. Error occurred during credential import from secret provider.
        ...    next_steps=Renew Azure service principal client secret in Azure portal: https://aka.ms/NewClientSecret\nUpdate workspace secrets with new client secret\nVerify AZURE_CLIENT_ID, AZURE_TENANT_ID, and AZURE_CLIENT_SECRET are correct\nEnsure service principal has proper permissions on the subscription
        # Set empty credentials to prevent further failures
        ${azure_credentials}=    Set Variable    ${EMPTY}
    END
    Set Suite Variable    ${AZURE_RESOURCE_SUBSCRIPTION_ID}    ${AZURE_RESOURCE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AKS_CLUSTER}    ${AKS_CLUSTER}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable    ${RW_LOOKBACK_WINDOW}    ${RW_LOOKBACK_WINDOW}
    Set Suite Variable    ${TIMEOUT_SECONDS}    ${TIMEOUT_SECONDS}
    Set Suite Variable
    ...    ${env}
    ...    {"AKS_CLUSTER":"${AKS_CLUSTER}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}", "RW_LOOKBACK_WINDOW": "${RW_LOOKBACK_WINDOW}", "AZURE_RESOURCE_SUBSCRIPTION_ID":"${AZURE_RESOURCE_SUBSCRIPTION_ID}"}
    # Set Azure subscription context only if credentials are valid
    IF    ${azure_credentials_status}
        ${az_account_result}=    RW.CLI.Run Cli
        ...    cmd=az account set --subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
        ...    include_in_history=false
        
        # Check if az account set failed (additional auth validation)
        IF    ${az_account_result.returncode} != 0
            RW.Core.Add Issue
            ...    severity=1
            ...    expected=Azure CLI should successfully set subscription context
            ...    actual=Azure CLI failed to set subscription context - authentication may have failed
            ...    title=Azure CLI Authentication Failed - Unable to Set Subscription Context
            ...    reproduce_hint=az account set --subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
            ...    details=Azure CLI command failed: ${az_account_result.stderr}\n\nThis typically indicates expired or invalid service principal credentials.
            ...    next_steps=Renew Azure service principal client secret in Azure portal: https://aka.ms/NewClientSecret\nUpdate workspace secrets with new client secret\nVerify service principal has access to subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}\nTest authentication manually: az login --service-principal --username <client-id> --password <client-secret> --tenant <tenant-id>
        END
    END
