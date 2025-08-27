*** Settings ***
Documentation       Calculates Azure ACR health by checking reachability, SKU, pull/push ratio, and storage utilization.
Metadata            Author    Nbarola
Metadata            Display Name    Azure ACR Health SLI
Metadata            Supports    Azure    Container Registry    ACR    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             Azure
Library             RW.platform
Library             String
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization

*** Tasks ***
Check ACR Reachability for Registry `${ACR_NAME}`
    [Documentation]    Checks if the ACR endpoint is reachable.
    [Tags]    ACR    Azure    Reachability    Health
    ${reachability}=    RW.CLI.Run Bash File
    ...    bash_file=acr_reachability.sh
    ...    env=${env}
    ...    timeout_seconds=120
    ...    include_in_history=false
    TRY
        ${issues}=    Evaluate    json.loads(r'''${reachability.stdout}''')    json
        ${score}=    Evaluate    0 if len(@{issues}) > 0 else 1
    EXCEPT
        Log    Failed to parse reachability issues JSON, defaulting to score 0
        ${score}=    Set Variable    0
    END
    Set Global Variable    ${reachability_score}    ${score}
    RW.Core.Push Metric    ${score}    sub_name=reachability

Check ACR Usage SKU Metric for Registry `${ACR_NAME}`
    [Documentation]    Checks the SKU and usage limits for the ACR.
    [Tags]    ACR    Azure    SKU    Health
    ${sku}=    RW.CLI.Run Bash File
    ...    bash_file=acr_usage_sku.sh
    ...    env=${env}
    ...    timeout_seconds=120
    ...    include_in_history=false
    TRY
        ${issues}=    Evaluate    json.loads(r'''${sku.stdout}''')    json
        ${score}=    Evaluate    0 if len(@{issues}) > 0 else 1
    EXCEPT
        Log    Failed to parse usage SKU issues JSON, defaulting to score 0
        ${score}=    Set Variable    0
    END
    Set Global Variable    ${sku_score}    ${score}
    RW.Core.Push Metric    ${score}    sub_name=sku_usage

Check ACR Pull/Push Success Ratio for Registry `${ACR_NAME}`
    [Documentation]    Checks the success rate of image pull and push operations.
    [Tags]    ACR    Azure    PullPush    Health
    ${ratio}=    RW.CLI.Run Bash File
    ...    bash_file=acr_pull_push_ratio.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    TRY
        ${issues}=    Evaluate    json.loads(r'''${ratio.stdout}''')    json
        ${score}=    Evaluate    0 if len(@{issues}) > 0 else 1
    EXCEPT
        Log    Failed to parse pull/push ratio issues JSON, defaulting to score 0
        ${score}=    Set Variable    0
    END
    Set Global Variable    ${pull_push_score}    ${score}
    RW.Core.Push Metric    ${score}    sub_name=pull_push_ratio

Check ACR Storage Utilization for Registry `${ACR_NAME}`
    [Documentation]    Checks the storage usage of the ACR.
    [Tags]    ACR    Azure    Storage    Health
    ${storage}=    RW.CLI.Run Bash File
    ...    bash_file=acr_storage_utilization.sh
    ...    env=${env}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ${issues_list}=    RW.CLI.Run Cli
    ...    cmd=cat storage_utilization_issues.json
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    TRY
        ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
        ${score}=    Evaluate    0 if len(@{issues}) > 0 else 1
    EXCEPT
        Log    Failed to parse storage utilization issues JSON, defaulting to score 0
        ${score}=    Set Variable    0
    END
    Set Global Variable    ${storage_score}    ${score}
    RW.Core.Push Metric    ${score}    sub_name=storage_utilization

Check ACR Network Configuration for Registry `${ACR_NAME}`
    [Documentation]    Checks network access rules, private endpoints, and connectivity.
    [Tags]    ACR    Azure    Network    Health
    ${network}=    RW.CLI.Run Bash File
    ...    bash_file=acr_network_config.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issues_list}=    RW.CLI.Run Cli
    ...    cmd=cat network_config_issues.json
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    TRY
        ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
        ${score}=    Evaluate    0 if len(@{issues}) > 0 else 1
    EXCEPT
        Log    Failed to parse network config issues JSON, defaulting to score 0
        ${score}=    Set Variable    0
    END
    Set Global Variable    ${network_score}    ${score}
    RW.Core.Push Metric    ${score}    sub_name=network_config



Check ACR Security Configuration
    [Documentation]    Analyzes ACR security configuration including RBAC, admin user settings, network access, and authentication methods.
    [Tags]    ACR    Azure    Security    RBAC    SLI
    
    TRY
        ${security_result}=    RW.CLI.Run Bash File
        ...    bash_file=acr_rbac_security.sh
        ...    env=${env}
        ...    timeout_seconds=60
        ...    include_in_history=false
        
        ${issues}=    Evaluate    json.loads(r'''${security_result.stdout}''')    json
        ${issue_count}=    Get Length    ${issues}
        
        # Calculate security score based on issues found
        # Severity 1 (critical) = -30 points, Severity 2 (high) = -20, Severity 3 (medium) = -10, Severity 4 (low) = -5
        ${penalty}=    Set Variable    0
        FOR    ${issue}    IN    @{issues}
            ${severity}=    Set Variable    ${issue["severity"]}
            IF    ${severity} == 1
                ${penalty}=    Evaluate    ${penalty} + 30
            ELSE IF    ${severity} == 2
                ${penalty}=    Evaluate    ${penalty} + 20
            ELSE IF    ${severity} == 3
                ${penalty}=    Evaluate    ${penalty} + 10
            ELSE IF    ${severity} == 4
                ${penalty}=    Evaluate    ${penalty} + 5
            END
        END
        
        # Calculate final score (100 - penalty, minimum 0), then normalize to 0-1 scale
        ${raw_score}=    Evaluate    max(0, 100 - ${penalty})
        ${score}=    Evaluate    ${raw_score} / 100.0
        
        Log    Security analysis completed. Issues found: ${issue_count}, Total penalty: ${penalty}, Score: ${score}
        
    EXCEPT
        Log    Security analysis failed, setting score to 0
        ${score}=    Set Variable    0
    END
    Set Global Variable    ${security_score}    ${score}
    RW.Core.Push Metric    ${score}    sub_name=security

Generate Comprehensive ACR Health Score for Registry `${ACR_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Aggregates all health check scores into a comprehensive health score.
    [Tags]    ACR    Azure    Health    Score    SLI
    
    # Calculate and push overall health score
    ${comprehensive_health_score}=    Evaluate    (${reachability_score} + ${sku_score} + ${pull_push_score} + ${storage_score} + ${network_score} + ${security_score}) / 6
    ${health_score}=    Convert to Number    ${comprehensive_health_score}    2
    RW.Core.Push Metric    ${health_score}

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
    ...    type=string
    ...    description=Storage usage warning threshold percentage.
    ...    pattern=\d+
    ...    default=80
    ${CRITICAL_THRESHOLD}=    RW.Core.Import User Variable    CRITICAL_THRESHOLD
    ...    type=string
    ...    description=Storage usage critical threshold percentage.
    ...    pattern=\d+
    ...    default=95
    ${TIME_PERIOD_HOURS}=    RW.Core.Import User Variable    TIME_PERIOD_HOURS
    ...    type=string
    ...    description=Time period in hours for pull/push metrics analysis.
    ...    pattern=\d+
    ...    default=24
    ${PULL_SUCCESS_THRESHOLD}=    RW.Core.Import User Variable    PULL_SUCCESS_THRESHOLD
    ...    type=string
    ...    description=Minimum pull success ratio percentage threshold.
    ...    pattern=\d+
    ...    default=95
    ${PUSH_SUCCESS_THRESHOLD}=    RW.Core.Import User Variable    PUSH_SUCCESS_THRESHOLD
    ...    type=string
    ...    description=Minimum push success ratio percentage threshold.
    ...    pattern=\d+
    ...    default=98
    Set Suite Variable    ${AZ_RESOURCE_GROUP}
    Set Suite Variable    ${ACR_NAME}
    Set Suite Variable    ${azure_credentials}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_NAME}
    Set Suite Variable    ${USAGE_THRESHOLD}
    Set Suite Variable    ${CRITICAL_THRESHOLD}
    Set Suite Variable    ${TIME_PERIOD_HOURS}
    Set Suite Variable    ${PULL_SUCCESS_THRESHOLD}
    Set Suite Variable    ${PUSH_SUCCESS_THRESHOLD}
    
    # Initialize all score variables to 0 to prevent undefined variable errors
    Set Global Variable    ${reachability_score}    0
    Set Global Variable    ${sku_score}    0
    Set Global Variable    ${pull_push_score}    0
    Set Global Variable    ${storage_score}    0
    Set Global Variable    ${network_score}    0

    Set Global Variable    ${security_score}    0
    
    Set Suite Variable
    ...    ${env}
    ...    {"ACR_NAME":"${ACR_NAME}","AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}","AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}","AZURE_SUBSCRIPTION_NAME":"${AZURE_SUBSCRIPTION_NAME}","USAGE_THRESHOLD":"${USAGE_THRESHOLD}","CRITICAL_THRESHOLD":"${CRITICAL_THRESHOLD}","TIME_PERIOD_HOURS":"${TIME_PERIOD_HOURS}","PULL_SUCCESS_THRESHOLD":"${PULL_SUCCESS_THRESHOLD}","PUSH_SUCCESS_THRESHOLD":"${PUSH_SUCCESS_THRESHOLD}"}