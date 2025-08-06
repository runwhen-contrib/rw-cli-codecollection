*** Settings ***
Documentation       Runs diagnostic checks against Azure Container Registry (ACR) to monitor reachability, SKU, pull/push success ratio, and storage utilization.
Metadata            Author    Nbarola
Metadata            Display Name    Azure ACR Health Check
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
    [Tags]    access:read-only    ACR    Azure    Reachability    Health
    ${reachability}=    RW.CLI.Run Bash File
    ...    bash_file=acr_reachability.sh
    ...    env=${env}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ${issues_list}=    RW.CLI.Run Cli
    ...    cmd=cat reachability_issues.json
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

Check ACR Usage SKU Metric for Registry `${ACR_NAME}`
    [Documentation]    Checks the SKU and usage limits for the ACR.
    [Tags]    access:read-only    ACR    Azure    SKU    Health
    ${sku}=    RW.CLI.Run Bash File
    ...    bash_file=acr_usage_sku.sh
    ...    env=${env}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ${issues_list}=    RW.CLI.Run Cli
    ...    cmd=cat usage_sku_issues.json
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

Check ACR Pull/Push Success Ratio for Registry `${ACR_NAME}`
    [Documentation]    Checks the success rate of image pull and push operations.
    [Tags]    access:read-only    ACR    Azure    PullPush    Health
    ${ratio}=    RW.CLI.Run Bash File
    ...    bash_file=acr_pull_push_ratio.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issues_list}=    RW.CLI.Run Cli
    ...    cmd=cat pull_push_ratio_issues.json
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

Check ACR Storage Utilization for Registry `${ACR_NAME}`
    [Documentation]    Checks the storage usage of the ACR.
    [Tags]    access:read-only    ACR    Azure    Storage    Health
    ${storage}=    RW.CLI.Run Bash File
    ...    bash_file=acr_storage_utilization.sh
    ...    env=${env}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ${issues_list}=    RW.CLI.Run Cli
    ...    cmd=cat storage_utilization_issues.json
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