*** Settings ***
Documentation       Validates that subnet egress paths align with NSGs, route tables, and optional Azure Firewall, and runs optional Network Watcher connectivity probes.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Azure Subnet Egress Path Validation
Metadata            Supports    Azure    Subnet    Network    Egress    NSG    Route    Firewall
Force Tags          Azure    Subnet    Network    Egress    NSG    Route    Firewall

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Discover Subnets and Attached NSGs in Scope for VNet `${VNET_NAME}`
    [Documentation]    Lists subnets in the VNet scope and resolves subnet IDs, attached NSGs, and route tables for downstream tasks.
    [Tags]    Azure    Subnet    Network    Discovery    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=subnet-discover-attachments.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./subnet-discover-attachments.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat subnet_discover_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for subnet discovery issues, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Subnet discovery should succeed without API or configuration errors for VNet `${VNET_NAME}`
            ...    actual=Discovery reported a problem for VNet `${VNET_NAME}` in resource group `${AZURE_RESOURCE_GROUP}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Summarize Effective Egress Rules per Subnet for VNet `${VNET_NAME}`
    [Documentation]    Aggregates NSG outbound rules for each subnet-attached NSG and highlights deny/allow posture for egress.
    [Tags]    Azure    Subnet    NSG    Egress    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=subnet-effective-nsg-egress.sh
    ...    env=${env}
    ...    timeout_seconds=240
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./subnet-effective-nsg-egress.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat subnet_effective_nsg_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for NSG egress issues, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=NSG egress rules should match intended allow/deny policy for subnets in `${VNET_NAME}`
            ...    actual=NSG egress analysis raised findings for subnets in `${VNET_NAME}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Validate Route Table and Firewall Next Hop for VNet `${VNET_NAME}`
    [Documentation]    Inspects UDRs for default routes and compares against Azure Firewall presence in the resource group to flag risky Internet bypass patterns.
    [Tags]    Azure    Subnet    Route    Firewall    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=subnet-route-firewall-check.sh
    ...    env=${env}
    ...    timeout_seconds=240
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./subnet-route-firewall-check.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat subnet_route_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for route/firewall issues, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Default routes and next hops should enforce centralized egress when Azure Firewall is deployed for `${AZURE_RESOURCE_GROUP}`
            ...    actual=Route analysis found potential misalignment between UDRs and Azure Firewall for VNet `${VNET_NAME}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Run Connectivity Probes for Egress Targets from VNet `${VNET_NAME}`
    [Documentation]    Uses Network Watcher test-connectivity from a source VM (or skips/bastion placeholder) to probe PROBE_TARGETS and compare outcomes to policy expectations.
    [Tags]    Azure    Subnet    NetworkWatcher    Probe    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=subnet-egress-probe.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./subnet-egress-probe.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat subnet_probe_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for probe issues, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Egress probes should reach allowed destinations from the source VM for `${VNET_NAME}` when policy permits
            ...    actual=One or more egress probes failed or could not run for targets in `${PROBE_TARGETS}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Report Egress Validation Summary for VNet `${VNET_NAME}`
    [Documentation]    Produces a merged per-subnet matrix from discovery, routes, and probes with consolidated issue counts for operators.
    [Tags]    Azure    Subnet    Summary    Report    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=subnet-egress-summary.sh
    ...    env=${env}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./subnet-egress-summary.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat subnet_summary_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for summary issues, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Prior validation steps should not leave unresolved merged findings for VNet `${VNET_NAME}`
            ...    actual=Merged validation output contains reported issues for subscription `${AZURE_SUBSCRIPTION_ID}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END


*** Keywords ***
Suite Initialization
    ${AZURE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=Azure subscription ID for the VNet.
    ...    pattern=[a-fA-F0-9-]+
    ${AZURE_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZURE_RESOURCE_GROUP
    ...    type=string
    ...    description=Resource group containing the virtual network.
    ...    pattern=\w*
    ${VNET_NAME}=    RW.Core.Import User Variable    VNET_NAME
    ...    type=string
    ...    description=Name of the virtual network to analyze.
    ...    pattern=[a-zA-Z0-9_.-]+
    ${PROBE_TARGETS}=    RW.Core.Import User Variable    PROBE_TARGETS
    ...    type=string
    ...    description=Comma-separated probe targets (https://host:port, http://host:port, or host:port).
    ...    pattern=\S+
    ${PROBE_MODE}=    RW.Core.Import User Variable    PROBE_MODE
    ...    type=string
    ...    description=Probe mode network-watcher, bastion-agent, or skip-probes.
    ...    pattern=\w+
    ...    default=network-watcher
    ${SOURCE_VM_RESOURCE_ID}=    RW.Core.Import User Variable    SOURCE_VM_RESOURCE_ID
    ...    type=string
    ...    description=Optional Azure Resource ID of a VM in the subnet for Network Watcher probes.
    ...    pattern=\S*
    ...    default=

    TRY
        ${azure_credentials}=    RW.Core.Import Secret
        ...    azure_credentials
        ...    type=string
        ...    description=JSON with AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
        ...    pattern=\w*
        Set Suite Variable    ${AZURE_CREDENTIALS}    ${azure_credentials}
    EXCEPT
        Log    azure_credentials secret not found; relying on existing Azure CLI session if any.    WARN
        Set Suite Variable    ${AZURE_CREDENTIALS}    ${EMPTY}
    END

    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${VNET_NAME}    ${VNET_NAME}
    Set Suite Variable    ${PROBE_TARGETS}    ${PROBE_TARGETS}
    Set Suite Variable    ${PROBE_MODE}    ${PROBE_MODE}
    Set Suite Variable    ${SOURCE_VM_RESOURCE_ID}    ${SOURCE_VM_RESOURCE_ID}

    ${env}=    Create Dictionary
    ...    AZURE_SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}
    ...    AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP}
    ...    VNET_NAME=${VNET_NAME}
    ...    PROBE_TARGETS=${PROBE_TARGETS}
    ...    PROBE_MODE=${PROBE_MODE}
    ...    SOURCE_VM_RESOURCE_ID=${SOURCE_VM_RESOURCE_ID}
    Set Suite Variable    ${env}    ${env}

    ${az_account_result}=    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZURE_SUBSCRIPTION_ID}
    ...    include_in_history=false
    IF    '${az_account_result.returncode}' != '0'
        Log    az account set failed; ensure Azure CLI is logged in or workspace secrets are valid.    WARN
    END
