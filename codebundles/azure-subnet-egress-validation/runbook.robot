*** Settings ***
Documentation       Validates that egress from subnets in an Azure VNet is enforced by NSGs, route tables, and optional probes via Network Watcher.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Azure Subnet Egress Path Validation
Metadata            Supports    Azure    Virtual Network    Subnet    NSG    Egress    Firewall    Network Watcher
Force Tags          Azure    VirtualNetwork    Subnet    Egress    NSG    Firewall

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Discover Subnets and Attached NSGs for VNet `${VNET_NAME}` in `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Lists subnets in scope, resolves subnet IDs, attached NSGs, and route tables for downstream egress checks.
    [Tags]    Azure    VirtualNetwork    Subnet    Discovery    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=subnet-discover-attachments.sh
    ...    env=${env}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./subnet-discover-attachments.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat subnet_discover_issues.json
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for discovery task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=Subnets in the VNet should be discoverable with NSG and route table associations resolved
            ...    actual=Discovery reported a configuration or API problem for this VNet scope
            ...    title=${issue["title"]}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_steps"]}
        END
    END

Summarize Effective Egress Rules per Subnet for VNet `${VNET_NAME}`
    [Documentation]    Aggregates NSG outbound rules affecting subnet traffic and highlights allow/deny posture for egress.
    [Tags]    Azure    NSG    Egress    Security    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=subnet-effective-nsg-egress.sh
    ...    env=${env}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./subnet-effective-nsg-egress.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat subnet_nsg_issues.json
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for NSG egress task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=NSG outbound rules should match documented least-privilege egress policy
            ...    actual=NSG egress posture for a subnet or NSG in scope needs review
            ...    title=${issue["title"]}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_steps"]}
        END
    END

Validate Route Table and Firewall Next Hop for VNet `${VNET_NAME}`
    [Documentation]    Inspects UDRs for default routes toward Azure Firewall or NVA when required by policy; flags missing forced tunneling.
    [Tags]    Azure    RouteTable    Firewall    UDR    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=subnet-route-firewall-check.sh
    ...    env=${env}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./subnet-route-firewall-check.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat subnet_route_issues.json
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for route check task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=Route tables should send Internet-bound traffic through the required firewall or NVA when policy mandates it
            ...    actual=Route or subnet association does not match expected egress path policy
            ...    title=${issue["title"]}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_steps"]}
        END
    END

Run Connectivity Probes for Egress Targets from Scope `${AZURE_SUBSCRIPTION_ID}`
    [Documentation]    Uses Network Watcher connection troubleshoot when configured, or degrades gracefully for bastion-agent and skip-probes modes.
    [Tags]    Azure    NetworkWatcher    Connectivity    Probe    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=subnet-egress-probe.sh
    ...    env=${env}
    ...    timeout_seconds=${TIMEOUT_SECONDS}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./subnet-egress-probe.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat subnet_probe_issues.json
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for probe task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=Probes to configured targets should succeed when policy allows egress
            ...    actual=Probe result indicates blocked, misconfigured, or incomplete egress validation
            ...    title=${issue["title"]}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_steps"]}
        END
    END

Report Egress Validation Summary for VNet `${VNET_NAME}`
    [Documentation]    Produces a pass/fail style matrix from prior checks and consolidates issues for reporting.
    [Tags]    Azure    VirtualNetwork    Summary    Report    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=subnet-egress-summary.sh
    ...    env=${env}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./subnet-egress-summary.sh

    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat subnet_egress_summary_issues.json
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
            ...    severity=${issue["severity"]}
            ...    expected=All prior egress validation stages should complete without outstanding issues when policy is satisfied
            ...    actual=One or more checks reported issues in the consolidated summary output
            ...    title=${issue["title"]}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_steps"]}
        END
    END


*** Keywords ***
Suite Initialization
    TRY
        ${azure_credentials}=    RW.Core.Import Secret
        ...    azure_credentials
        ...    type=string
        ...    description=JSON with AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET for Azure CLI
        ...    pattern=\w*
        Set Suite Variable    ${AZURE_CREDENTIALS_PRESENT}    ${TRUE}
    EXCEPT
        Log    Azure credentials secret not loaded; ensure the workspace provides azure_credentials for az CLI.    WARN
        Set Suite Variable    ${AZURE_CREDENTIALS_PRESENT}    ${FALSE}
    END

    ${AZURE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=Azure subscription ID containing the VNet.
    ...    pattern=[0-9a-fA-F-]+
    ${AZURE_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZURE_RESOURCE_GROUP
    ...    type=string
    ...    description=Resource group that contains the virtual network.
    ...    pattern=\w[\w.-]*
    ${VNET_NAME}=    RW.Core.Import User Variable    VNET_NAME
    ...    type=string
    ...    description=Name of the virtual network to analyze.
    ...    pattern=\w[\w.-]*
    ${PROBE_TARGETS}=    RW.Core.Import User Variable    PROBE_TARGETS
    ...    type=string
    ...    description=Comma-separated host:port or URL list for egress probes.
    ...    pattern=.*
    ${PROBE_MODE}=    RW.Core.Import User Variable    PROBE_MODE
    ...    type=string
    ...    description=network-watcher, bastion-agent, or skip-probes.
    ...    pattern=\w[\w-]*
    ...    default=network-watcher
    ${SOURCE_VM_RESOURCE_ID}=    RW.Core.Import User Variable    SOURCE_VM_RESOURCE_ID
    ...    type=string
    ...    description=Optional VM resource ID in the subnet for Network Watcher connection tests.
    ...    pattern=.*
    ...    default=${EMPTY}
    ${SUBNET_NAME_FILTER}=    RW.Core.Import User Variable    SUBNET_NAME_FILTER
    ...    type=string
    ...    description=Optional comma-separated subnet names to include (empty = all subnets).
    ...    pattern=.*
    ...    default=${EMPTY}
    ${REQUIRE_DEFAULT_ROUTE_VIA_FIREWALL}=    RW.Core.Import User Variable    REQUIRE_DEFAULT_ROUTE_VIA_FIREWALL
    ...    type=string
    ...    description=When true, require a 0.0.0.0/0 UDR via VirtualAppliance or Firewall on subnet route tables.
    ...    pattern=.*
    ...    default=false
    ${TIMEOUT_SECONDS}=    RW.Core.Import User Variable    TIMEOUT_SECONDS
    ...    type=string
    ...    description=Timeout for bash analysis scripts in seconds.
    ...    pattern=\d+
    ...    default=300

    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${VNET_NAME}    ${VNET_NAME}
    Set Suite Variable    ${PROBE_TARGETS}    ${PROBE_TARGETS}
    Set Suite Variable    ${PROBE_MODE}    ${PROBE_MODE}
    Set Suite Variable    ${SOURCE_VM_RESOURCE_ID}    ${SOURCE_VM_RESOURCE_ID}
    Set Suite Variable    ${SUBNET_NAME_FILTER}    ${SUBNET_NAME_FILTER}
    Set Suite Variable    ${REQUIRE_DEFAULT_ROUTE_VIA_FIREWALL}    ${REQUIRE_DEFAULT_ROUTE_VIA_FIREWALL}
    Set Suite Variable    ${TIMEOUT_SECONDS}    ${TIMEOUT_SECONDS}

    ${env}=    Create Dictionary
    ...    AZURE_SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}
    ...    AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP}
    ...    VNET_NAME=${VNET_NAME}
    ...    PROBE_TARGETS=${PROBE_TARGETS}
    ...    PROBE_MODE=${PROBE_MODE}
    ...    SOURCE_VM_RESOURCE_ID=${SOURCE_VM_RESOURCE_ID}
    ...    SUBNET_NAME_FILTER=${SUBNET_NAME_FILTER}
    ...    REQUIRE_DEFAULT_ROUTE_VIA_FIREWALL=${REQUIRE_DEFAULT_ROUTE_VIA_FIREWALL}
    Set Suite Variable    ${env}    ${env}

    IF    ${AZURE_CREDENTIALS_PRESENT}
        ${az_set}=    RW.CLI.Run Cli
        ...    cmd=az account set --subscription ${AZURE_SUBSCRIPTION_ID}
        ...    include_in_history=false
        Log    Azure subscription context set to ${AZURE_SUBSCRIPTION_ID}
    END
