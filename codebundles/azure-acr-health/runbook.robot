*** Settings ***
Documentation       Runs diagnostic checks against Azure Container Registry (ACR), including DNS/TLS, authentication, SKU/usage, storage, pull/push, geo-replication, repository events, and retention health.
Metadata            Author    Nbarola
Metadata            Display Name    Azure ACR Health Check
Metadata            Supports    Azure    Container Registry    ACR    Health    Push    Pull    Storage

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
Check DNS & TLS Reachability for Registry `${ACR_NAME}`
    [Documentation]    Verifies DNS resolution and HTTPS/TLS for ACR endpoint.
    [Tags]    access:read-only    ACR    Azure    DNS    TLS    Connectivity    Health
    ${dns_tls}=    RW.CLI.Run Bash File
    ...    bash_file=acr_dns_tls_reachability.sh
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ${issues_list}=    RW.CLI.Run Cli
    ...    cmd=cat dns_tls_issues.json
    ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
    IF    len(@{issues}) > 0
        FOR    ${issue}    IN    @{issues}
            RW.Core.Add Issue
            ...    severity=${issue}["severity"]
            ...    title=${issue}["title"]
            ...    expected=${issue}["expected"]
            ...    actual=${issue}["actual"]
            ...    reproduce_hint=${issue}.get("reproduce_hint", "")
            ...    details=${issue}["details"]
            ...    next_steps=${issue}["next_steps"]
        END
    END

Check ACR Login & Authentication for Registry `${ACR_NAME}`
    [Documentation]    Attempts az acr login and docker login using intended workload identity.
    [Tags]    access:read-only    ACR    Azure    Login    Auth    Connectivity    Health
    ${login}=    RW.CLI.Run Bash File
    ...    bash_file=acr_login_check.sh
    ...    env=${env}
    ...    timeout_seconds=90
    ...    include_in_history=false
    ${issues_list}=    RW.CLI.Run Cli
    ...    cmd=cat acr_login_issues.json
    ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
    IF    len(@{issues}) > 0
        FOR    ${issue}    IN    @{issues}
            RW.Core.Add Issue
            ...    severity=${issue}["severity"]
            ...    title=${issue}["title"]
            ...    expected=${issue}["expected"]
            ...    actual=${issue}["actual"]
            ...    reproduce_hint=${issue}.get("reproduce_hint", "")
            ...    details=${issue}["details"]
            ...    next_steps=${issue}["next_steps"]
        END
    END

Check ACR Storage Usage for Registry `${ACR_NAME}`
    [Documentation]    Checks storage used vs quota using az acr show-usage.
    [Tags]    access:read-only    ACR    Azure    Storage    Health
    ${storage}=    RW.CLI.Run Bash File
    ...    bash_file=acr_storage_usage.sh
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ${issues_list}=    RW.CLI.Run Cli
    ...    cmd=cat storage_usage_issues.json
    ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
    IF    len(@{issues}) > 0
        FOR    ${issue}    IN    @{issues}
            RW.Core.Add Issue
            ...    severity=${issue}["severity"]
            ...    title=${issue}["title"]
            ...    expected=${issue}["expected"]
            ...    actual=${issue}["actual"]
            ...    reproduce_hint=${issue}.get("reproduce_hint", "")
            ...    details=${issue}["details"]
            ...    next_steps=${issue}["next_steps"]
        END
    END


Check ACR Repository Event Failures for Registry `${ACR_NAME}`
    [Documentation]    Queries Log Analytics for recent failed pushes/pulls and repo errors.
    [Tags]    access:read-only    ACR    Azure    Events    Health
    ${repo_events}=    RW.CLI.Run Bash File
    ...    bash_file=acr_repository_events.sh
    ...    env=${env}
    ...    timeout_seconds=90
    ...    include_in_history=false
    ${issues_list}=    RW.CLI.Run Cli
    ...    cmd=cat repository_events_issues.json
    ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
    IF    len(@{issues}) > 0
        FOR    ${issue}    IN    @{issues}
            RW.Core.Add Issue
            ...    severity=${issue}["severity"]
            ...    title=${issue}["title"]
            ...    expected=${issue}["expected"]
            ...    actual=${issue}["actual"]
            ...    reproduce_hint=${issue}.get("reproduce_hint", "")
            ...    details=${issue}["details"]
            ...    next_steps=${issue}["next_steps"]
        END
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
    ${ACR_PASSWORD}=    RW.Core.Import Secret    acr_admin_password
    ...    type=string
    ...    description=Azure Container Registry password (admin or SP credential).
    ...    pattern=.*
    ${AZURE_RESOURCE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure Subscription ID.
    ...    pattern=\w*
    ${AZURE_SUBSCRIPTION_NAME}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_NAME
    ...    type=string
    ...    description=The Azure Subscription Name.
    ...    pattern=\w*
    ${LOG_WORKSPACE_ID}=    RW.Core.Import User Variable    LOG_WORKSPACE_ID
    ...    type=string
    ...    description=Log Analytics Workspace ID for querying diagnostic events.
    ...    pattern=\w*
    Set Suite Variable    ${ACR_NAME}    ${ACR_NAME}
    Set Suite Variable    ${ACR_PASSWORD}    ${ACR_PASSWORD}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_RESOURCE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_NAME}    ${AZURE_SUBSCRIPTION_NAME}
    Set Suite Variable    ${LOG_WORKSPACE_ID}    ${LOG_WORKSPACE_ID}
    Set Suite Variable
    ...    ${env}
    ...    {"ACR_NAME": "${ACR_NAME}", "${ACR_PASSWORD}": "${ACR_PASSWORD}", "AZ_RESOURCE_GROUP": "${AZ_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID": "${AZURE_RESOURCE_SUBSCRIPTION_ID}", "AZURE_SUBSCRIPTION_NAME": "${AZURE_SUBSCRIPTION_NAME}", "LOG_WORKSPACE_ID": "${LOG_WORKSPACE_ID}"}
    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
    ...    include_in_history=false
