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
    ${issues_list}=    RW.CLI.Run Cli
    ...    cmd=cat reachability_issues.json
    ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
    ${score}=    Evaluate    0 if len(@{issues}) > 0 else 1
    Set Global Variable    ${reachability_score}    ${score}

Check ACR Usage SKU Metric for Registry `${ACR_NAME}`
    [Documentation]    Checks the SKU and usage limits for the ACR.
    [Tags]    ACR    Azure    SKU    Health
    ${sku}=    RW.CLI.Run Bash File
    ...    bash_file=acr_usage_sku.sh
    ...    env=${env}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ${issues_list}=    RW.CLI.Run Cli
    ...    cmd=cat usage_sku_issues.json
    ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
    ${score}=    Evaluate    0 if len(@{issues}) > 0 else 1
    Set Global Variable    ${sku_score}    ${score}

Check ACR Pull/Push Success Ratio for Registry `${ACR_NAME}`
    [Documentation]    Checks the success rate of image pull and push operations.
    [Tags]    ACR    Azure    PullPush    Health
    ${ratio}=    RW.CLI.Run Bash File
    ...    bash_file=acr_pull_push_ratio.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issues_list}=    RW.CLI.Run Cli
    ...    cmd=cat pull_push_ratio_issues.json
    ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
    ${score}=    Evaluate    0 if len(@{issues}) > 0 else 1
    Set Global Variable    ${pull_push_score}    ${score}

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
    ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
    ${score}=    Evaluate    0 if len(@{issues}) > 0 else 1
    Set Global Variable    ${storage_score}    ${score} 