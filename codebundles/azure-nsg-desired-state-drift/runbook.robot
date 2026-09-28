*** Settings ***
Documentation       Compares live Azure Network Security Group rules and associations against a repo-managed baseline to detect out-of-band drift.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Azure NSG Desired-State Drift Detection
Metadata            Supports    Azure    NSG    Network Security    Drift    Compliance    Baseline
Force Tags          Azure    NSG    Network Security    Drift    Baseline

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Export Live NSG Rules for Comparison in Subscription `${AZURE_SUBSCRIPTION_ID}`
    [Documentation]    For each NSG in scope, exports security rules and default rules in stable JSON (subscription, resource group, NSG name, rule set) for diffing against the baseline.
    [Tags]    Azure    NSG    Drift    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=nsg-export-live-rules.sh
    ...    env=${env}
    ...    secret__azure_credentials=${AZURE_CREDENTIALS}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=AZURE_SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID} ./nsg-export-live-rules.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=test -f nsg_export_issues.json && cat nsg_export_issues.json || echo '[]'
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for export task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Azure CLI can list NSGs and export rules in the configured scope
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Load and Normalize Baseline NSG Definition for `${BASELINE_PATH}`
    [Documentation]    Reads the baseline from BASELINE_PATH (JSON bundle or per-NSG directory) and normalizes it to the same schema as the live export for comparison.
    [Tags]    Azure    NSG    Baseline    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=nsg-load-baseline.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=BASELINE_PATH=${BASELINE_PATH} ./nsg-load-baseline.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=test -f nsg_baseline_issues.json && cat nsg_baseline_issues.json || echo '[]'
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for baseline task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Baseline file or directory is readable and matches the supported NSG JSON schema
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Diff Live vs Baseline and Report Drift for Subscription `${AZURE_SUBSCRIPTION_ID}`
    [Documentation]    Compares normalized live NSG state to the baseline; flags added, removed, or changed rules (priority, direction, access, protocol, ports, addresses) and emits actionable issues per drift category.
    [Tags]    Azure    NSG    Drift    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=nsg-diff-desired-state.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./nsg-diff-desired-state.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=test -f nsg_diff_issues.json && cat nsg_diff_issues.json || echo '[]'
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for diff task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Live NSG rules should match the declared baseline with no unauthorized edits
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Validate Subnet and NIC NSG Associations in Subscription `${AZURE_SUBSCRIPTION_ID}`
    [Documentation]    Cross-checks subnet and NIC attachments for each NSG in scope; optionally compares association lists to ASSOCIATION_BASELINE_PATH when provided.
    [Tags]    Azure    NSG    Associations    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=nsg-association-audit.sh
    ...    env=${env}
    ...    secret__azure_credentials=${AZURE_CREDENTIALS}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./nsg-association-audit.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=test -f nsg_assoc_issues.json && cat nsg_assoc_issues.json || echo '[]'
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for association task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=NSG associations should match the intended subnet and NIC attachments
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Summarize Drift Scope for Operators in Subscription `${AZURE_SUBSCRIPTION_ID}`
    [Documentation]    Aggregates drift counts, prints Azure Portal links for NSGs in scope, and suggests rollback via pipeline or IaC reconcile.
    [Tags]    Azure    NSG    Summary    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=nsg-drift-summary.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./nsg-drift-summary.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=test -f nsg_summary_issues.json && cat nsg_summary_issues.json || echo '[]'
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for summary task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Operators should see a clear rollup of NSG drift and links for remediation
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END


*** Keywords ***
Suite Initialization
    ${AZURE_CREDENTIALS}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=JSON with AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET for Azure Resource Manager read access
    ...    pattern=\w*

    ${AZURE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=Azure subscription ID for NSG scope
    ...    pattern=[a-fA-F0-9-]+

    ${AZURE_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZURE_RESOURCE_GROUP
    ...    type=string
    ...    description=Resource group containing NSGs (empty lists NSGs across the subscription; may be slower)
    ...    pattern=.*
    ...    default=

    ${NSG_NAMES}=    RW.Core.Import User Variable    NSG_NAMES
    ...    type=string
    ...    description=Comma-separated NSG names or All for every NSG in the resource group or subscription scope
    ...    pattern=.*
    ...    default=All

    ${NSG_NAME}=    RW.Core.Import User Variable    NSG_NAME
    ...    type=string
    ...    description=When set (for example by generation), restricts analysis to this single NSG name
    ...    pattern=.*
    ...    default=

    ${BASELINE_PATH}=    RW.Core.Import User Variable    BASELINE_PATH
    ...    type=string
    ...    description=Path to baseline JSON bundle or directory of per-NSG exports matching the live export schema
    ...    pattern=.*

    ${BASELINE_FORMAT}=    RW.Core.Import User Variable    BASELINE_FORMAT
    ...    type=string
    ...    description=Baseline layout json-bundle (single file with nsgs array) or per-nsg-dir
    ...    pattern=.*
    ...    default=json-bundle

    ${ASSOCIATION_BASELINE_PATH}=    RW.Core.Import User Variable    ASSOCIATION_BASELINE_PATH
    ...    type=string
    ...    description=Optional JSON file with subnet and NIC IDs per NSG for association drift checks
    ...    pattern=.*
    ...    default=

    ${COMPARE_DEFAULT_RULES}=    RW.Core.Import User Variable    COMPARE_DEFAULT_RULES
    ...    type=string
    ...    description=When true, include Azure default security rules in the diff (usually leave false)
    ...    pattern=.*
    ...    default=false

    ${IGNORE_RULE_PREFIXES}=    RW.Core.Import User Variable    IGNORE_RULE_PREFIXES
    ...    type=string
    ...    description=Comma-separated rule name prefixes to skip when comparing (for example Azure platform rules)
    ...    pattern=.*
    ...    default=

    ${REQUIRE_ASSOCIATIONS}=    RW.Core.Import User Variable    REQUIRE_ASSOCIATIONS
    ...    type=string
    ...    description=When true, emit a warning if an NSG has no subnet or NIC attachments
    ...    pattern=.*
    ...    default=false

    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${NSG_NAMES}    ${NSG_NAMES}
    Set Suite Variable    ${NSG_NAME}    ${NSG_NAME}
    Set Suite Variable    ${BASELINE_PATH}    ${BASELINE_PATH}
    Set Suite Variable    ${BASELINE_FORMAT}    ${BASELINE_FORMAT}
    Set Suite Variable    ${ASSOCIATION_BASELINE_PATH}    ${ASSOCIATION_BASELINE_PATH}
    Set Suite Variable    ${COMPARE_DEFAULT_RULES}    ${COMPARE_DEFAULT_RULES}
    Set Suite Variable    ${IGNORE_RULE_PREFIXES}    ${IGNORE_RULE_PREFIXES}
    Set Suite Variable    ${REQUIRE_ASSOCIATIONS}    ${REQUIRE_ASSOCIATIONS}
    Set Suite Variable    ${AZURE_CREDENTIALS}    ${AZURE_CREDENTIALS}

    ${env}=    Create Dictionary
    ...    AZURE_SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}
    ...    AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP}
    ...    NSG_NAMES=${NSG_NAMES}
    ...    NSG_NAME=${NSG_NAME}
    ...    BASELINE_PATH=${BASELINE_PATH}
    ...    BASELINE_FORMAT=${BASELINE_FORMAT}
    ...    ASSOCIATION_BASELINE_PATH=${ASSOCIATION_BASELINE_PATH}
    ...    COMPARE_DEFAULT_RULES=${COMPARE_DEFAULT_RULES}
    ...    IGNORE_RULE_PREFIXES=${IGNORE_RULE_PREFIXES}
    ...    REQUIRE_ASSOCIATIONS=${REQUIRE_ASSOCIATIONS}
    ...    AZURE_CREDENTIALS=${AZURE_CREDENTIALS}
    Set Suite Variable    ${env}    ${env}
