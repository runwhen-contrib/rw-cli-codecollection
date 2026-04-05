*** Settings ***
Documentation       Detects Network Security Group drift by comparing live Azure NSG rules and associations against a repo-managed baseline JSON for unauthorized or out-of-band changes.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Azure NSG Desired-State Drift Detection
Metadata            Supports    Azure    NSG    Network Security    Drift    Compliance
Force Tags          Azure    NSG    Network Security    Drift    Compliance

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Export Live NSG Rules for Comparison for `${NSG_NAME}`
    [Documentation]    Exports the current NSG security rules, default rules, and associations into stable JSON (nsg_live_export.json) for diffing against the baseline.
    [Tags]    Azure    NSG    Drift    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=nsg-export-live-rules.sh
    ...    env=${env}
    ...    secret__azure_credentials=${azure_credentials}
    ...    timeout_seconds=240
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./nsg-export-live-rules.sh
    ${issues_raw}=    RW.CLI.Run Cli
    ...    cmd=test -f nsg_export_issues.json && cat nsg_export_issues.json || echo []
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues_raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse export issues JSON.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Live NSG export should succeed for in-scope readers
            ...    actual=${issue['title']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Live NSG export output:\n${result.stdout}

Load and Normalize Baseline NSG Definition for `${NSG_NAME}`
    [Documentation]    Reads baseline JSON from BASELINE_PATH (bundle file, URL, or per-NSG directory) and normalizes it to the same schema as the live export for comparison.
    [Tags]    Azure    NSG    Baseline    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=nsg-load-baseline.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=./nsg-load-baseline.sh
    ${issues_raw}=    RW.CLI.Run Cli
    ...    cmd=test -f nsg_baseline_issues.json && cat nsg_baseline_issues.json || echo []
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues_raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse baseline issues JSON.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Baseline file should exist and contain this NSG definition
            ...    actual=${issue['title']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Baseline load output:\n${result.stdout}

Diff Live vs Baseline and Report Drift for `${NSG_NAME}`
    [Documentation]    Compares normalized live and baseline security rules; raises issues for added, removed, or changed rules (priority, direction, access, ports, addresses).
    [Tags]    Azure    NSG    Drift    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=nsg-diff-desired-state.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=./nsg-diff-desired-state.sh
    ${issues_raw}=    RW.CLI.Run Cli
    ...    cmd=test -f nsg_diff_issues.json && cat nsg_diff_issues.json || echo []
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues_raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse diff issues JSON.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Live NSG rules should match the declared baseline
            ...    actual=${issue['title']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Rule drift diff output:\n${result.stdout}

Validate Subnet and NIC NSG Associations for `${NSG_NAME}`
    [Documentation]    Compares subnet and NIC attachment lists between live export and baseline when the baseline includes an associations block.
    [Tags]    Azure    NSG    Associations    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=nsg-association-audit.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=./nsg-association-audit.sh
    ${issues_raw}=    RW.CLI.Run Cli
    ...    cmd=test -f nsg_association_issues.json && cat nsg_association_issues.json || echo []
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues_raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse association issues JSON.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Subnet and NIC associations should match baseline when baseline lists them
            ...    actual=${issue['title']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Association audit output:\n${result.stdout}

Summarize Drift Scope for Operators for `${NSG_NAME}`
    [Documentation]    Aggregates drift counts, links to the Azure Portal resource, and suggests rollback or IaC reconciliation paths.
    [Tags]    Azure    NSG    Summary    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=nsg-drift-summary.sh
    ...    env=${env}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ...    cmd_override=./nsg-drift-summary.sh
    ${issues_raw}=    RW.CLI.Run Cli
    ...    cmd=test -f nsg_summary_issues.json && cat nsg_summary_issues.json || echo []
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues_raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse summary issues JSON.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Operators should receive a concise drift summary with portal links
            ...    actual=${issue['title']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Drift summary output:\n${result.stdout}


*** Keywords ***
Suite Initialization
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=JSON with AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET for Azure Resource Manager read access
    ...    pattern=.*
    ${AZURE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=Azure subscription ID containing the NSG
    ...    pattern=[\w-]*
    ${AZURE_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZURE_RESOURCE_GROUP
    ...    type=string
    ...    description=Resource group containing the NSG; leave empty to discover RG by NSG name
    ...    default=
    ...    pattern=[\w.-]*
    ${NSG_NAME}=    RW.Core.Import User Variable    NSG_NAME
    ...    type=string
    ...    description=Network Security Group name for this SLX
    ...    pattern=[\w.-]*
    ${BASELINE_PATH}=    RW.Core.Import User Variable    BASELINE_PATH
    ...    type=string
    ...    description=Path or HTTPS URL to baseline JSON bundle, or directory when using per-nsg-dir format
    ...    pattern=.*
    ${BASELINE_FORMAT}=    RW.Core.Import User Variable    BASELINE_FORMAT
    ...    type=string
    ...    description=Baseline layout - json-bundle (single file or URL) or per-nsg-dir
    ...    default=json-bundle
    ...    pattern=\w[\w-]*
    ${IGNORE_RULE_PREFIXES}=    RW.Core.Import User Variable    IGNORE_RULE_PREFIXES
    ...    type=string
    ...    description=Comma-separated rule name prefixes to exclude from drift comparison (e.g. platform defaults)
    ...    default=
    ...    pattern=.*
    ${COMPARE_DEFAULT_RULES}=    RW.Core.Import User Variable    COMPARE_DEFAULT_RULES
    ...    type=string
    ...    description=When true, compares defaultSecurityRules between live and baseline
    ...    default=false
    ...    pattern=\w*
    Set Suite Variable    ${azure_credentials}    ${azure_credentials}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${NSG_NAME}    ${NSG_NAME}
    Set Suite Variable    ${BASELINE_PATH}    ${BASELINE_PATH}
    Set Suite Variable    ${BASELINE_FORMAT}    ${BASELINE_FORMAT}
    Set Suite Variable    ${IGNORE_RULE_PREFIXES}    ${IGNORE_RULE_PREFIXES}
    Set Suite Variable    ${COMPARE_DEFAULT_RULES}    ${COMPARE_DEFAULT_RULES}
    ${env}=    Create Dictionary
    ...    AZURE_SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}
    ...    AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP}
    ...    NSG_NAME=${NSG_NAME}
    ...    BASELINE_PATH=${BASELINE_PATH}
    ...    BASELINE_FORMAT=${BASELINE_FORMAT}
    ...    IGNORE_RULE_PREFIXES=${IGNORE_RULE_PREFIXES}
    ...    COMPARE_DEFAULT_RULES=${COMPARE_DEFAULT_RULES}
    Set Suite Variable    ${env}    ${env}
    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZURE_SUBSCRIPTION_ID}
    ...    include_in_history=false
