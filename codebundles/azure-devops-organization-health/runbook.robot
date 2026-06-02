*** Settings ***
Documentation       Comprehensive Azure DevOps organization health monitoring focusing on platform-wide issues and shared resources
Metadata            Author    stewartshea
Metadata            Display Name    Azure DevOps Organization Health
Metadata            Supports    AzureDevOps,CICD
Force Tags          AzureDevOps    CICD

Library    String
Library             BuiltIn
Library             OperatingSystem
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Validate Azure DevOps Access for Organization `${AZURE_DEVOPS_ORG}`
    [Documentation]    Surfaces the suite preflight result. Raises an issue when the configured identity lacks the access required to run the core organization-health checks, so the gap is reported instead of failing silently downstream.
    [Tags]    Organization    Preflight    Access    Permissions    access:read-only

    ${access_ok}=    Evaluate    bool(${PREFLIGHT_DATA}.get('access_ok', False))
    IF    not ${access_ok}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=The configured identity has the PAT scopes / Azure DevOps roles required for organization health checks in `${AZURE_DEVOPS_ORG}`
        ...    actual=${PREFLIGHT_SUMMARY}
        ...    title=Insufficient Azure DevOps Access for Organization `${AZURE_DEVOPS_ORG}`
        ...    reproduce_hint=preflight-check.sh
        ...    details=${PREFLIGHT_DETAILS}
        ...    next_steps=For each capability marked DENIED/ERROR in the matrix above, grant the listed PAT scope (Azure DevOps > User settings > Personal access tokens > Edit > Scopes) and the listed organization/project role, then re-run. If the matrix shows all capabilities OK, the preflight script failed to record its result rather than a true permission gap — re-run and check the raw preflight output.
    END

    RW.Core.Add Pre To Report    Preflight Access Summary:
    RW.Core.Add Pre To Report    ${PREFLIGHT_DETAILS}

Check Service Health Status for Azure DevOps Organization `${AZURE_DEVOPS_ORG}`
    [Documentation]    Tests connectivity and access to core Azure DevOps APIs and services. Identifies service issues vs permission limitations.
    [Tags]    Organization    Service    Health    Platform    access:read-only    data:logs-config
    
    ${service_health}=    RW.CLI.Run Bash File
    ...    bash_file=organization-service-health.sh
    ...    env=${env}
    ...    secret__azure_devops_pat=${AZURE_DEVOPS_PAT}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat organization_service_health.json
    
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to load service health JSON payload, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Azure DevOps services should be healthy for organization `${AZURE_DEVOPS_ORG}`
            ...    actual=Service health issues detected in organization `${AZURE_DEVOPS_ORG}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${service_health.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    
    RW.Core.Add Pre To Report    Organization Service Health Status:
    RW.Core.Add Pre To Report    ${service_health.stdout}

Check Agent Pool Capacity and Utilization for Organization `${AZURE_DEVOPS_ORG}`
    [Documentation]    Analyzes self-hosted agent pools for capacity issues including offline agents, utilization thresholds, and configuration problems.
    [Tags]    Organization    AgentPools    Capacity    Distribution    access:read-only    data:logs-bulk
    
    ${agent_capacity}=    RW.CLI.Run Bash File
    ...    bash_file=agent-pool-capacity.sh
    ...    env=${env}
    ...    secret__azure_devops_pat=${AZURE_DEVOPS_PAT}
    ...    timeout_seconds=600
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat agent_pool_capacity.json
    
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to load agent capacity JSON payload — the script likely timed out or the API was unreachable.    WARN
        ${issue_list}=    Create List
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Agent pool capacity data should be collected for organization `${AZURE_DEVOPS_ORG}`
        ...    actual=Agent pool capacity collection produced no output (likely a timeout while enumerating agents across all pools, or the API was unreachable)
        ...    title=Agent Pool Capacity Collection Failed for `${AZURE_DEVOPS_ORG}`
        ...    reproduce_hint=${agent_capacity.cmd}
        ...    details=agent-pool-capacity.sh did not produce valid JSON. For organizations with many pools, raise AGENT_FETCH_PARALLELISM and/or the task timeout. Preflight: ${PREFLIGHT_SUMMARY}
        ...    next_steps=Increase AGENT_FETCH_PARALLELISM (default 20), confirm Agent Pools (Read) access, and verify dev.azure.com connectivity from the runner.
    END
    
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Agent pools should have adequate capacity in organization `${AZURE_DEVOPS_ORG}`
            ...    actual=Agent pool capacity issues detected in organization `${AZURE_DEVOPS_ORG}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${agent_capacity.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    
    RW.Core.Add Pre To Report    Agent Pool Capacity Analysis:
    RW.Core.Add Pre To Report    ${agent_capacity.stdout}

Validate Organization Policies and Security Settings for `${AZURE_DEVOPS_ORG}`
    [Documentation]    Examines organization security groups, user access levels, and policy configurations. Requires elevated permissions for full analysis.
    [Tags]    Organization    Policies    Compliance    Security    access:read-only    data:logs-config
    
    ${org_policies}=    RW.CLI.Run Bash File
    ...    bash_file=organization-policies.sh
    ...    env=${env}
    ...    secret__azure_devops_pat=${AZURE_DEVOPS_PAT}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat organization_policies.json
    
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to load organization policies JSON payload, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Organization policies should be properly configured in `${AZURE_DEVOPS_ORG}`
            ...    actual=Organization policy issues detected in `${AZURE_DEVOPS_ORG}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${org_policies.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    
    RW.Core.Add Pre To Report    Organization Policies and Compliance:
    RW.Core.Add Pre To Report    ${org_policies.stdout}

Check License Utilization and Capacity for Organization `${AZURE_DEVOPS_ORG}`
    [Documentation]    Analyzes user license assignments for cost optimization opportunities and identifies inactive users or licensing inefficiencies.
    [Tags]    Organization    Licenses    Capacity    Utilization    access:read-only    data:logs-config
    
    ${license_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=license-utilization.sh
    ...    env=${env}
    ...    secret__azure_devops_pat=${AZURE_DEVOPS_PAT}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat license_utilization.json
    
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to load license utilization JSON payload, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=License utilization should be within acceptable limits in `${AZURE_DEVOPS_ORG}`
            ...    actual=License utilization issues detected in `${AZURE_DEVOPS_ORG}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${license_analysis.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    
    RW.Core.Add Pre To Report    License Utilization Analysis:
    RW.Core.Add Pre To Report    ${license_analysis.stdout}

Investigate Platform-wide Service Incidents for Organization `${AZURE_DEVOPS_ORG}`
    [Documentation]    Monitors Azure DevOps platform status and detects service-wide incidents by checking official status pages and API performance.
    [Tags]    Organization    Incidents    Platform    Service    access:read-only    data:logs-bulk
    
    ${service_incidents}=    RW.CLI.Run Bash File
    ...    bash_file=service-incident-check.sh
    ...    env=${env}
    ...    secret__azure_devops_pat=${AZURE_DEVOPS_PAT}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat service_incidents.json
    
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to load service incidents JSON payload, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Azure DevOps platform should be operating normally for organization `${AZURE_DEVOPS_ORG}`
            ...    actual=Platform service incidents detected affecting organization `${AZURE_DEVOPS_ORG}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${service_incidents.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    
    RW.Core.Add Pre To Report    Platform Service Incidents:
    RW.Core.Add Pre To Report    ${service_incidents.stdout}

Analyze Cross-Project Dependencies for Organization `${AZURE_DEVOPS_ORG}`
    [Documentation]    Identifies shared resources between projects including agent pools, service connections, and potential naming conflicts.
    [Tags]    Organization    Dependencies    Projects    Integration    access:read-only    data:logs-config
    
    ${cross_deps}=    RW.CLI.Run Bash File
    ...    bash_file=cross-project-dependencies.sh
    ...    env=${env}
    ...    secret__azure_devops_pat=${AZURE_DEVOPS_PAT}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat cross_project_dependencies.json
    
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to load cross-project dependencies JSON payload, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Cross-project dependencies should be healthy in organization `${AZURE_DEVOPS_ORG}`
            ...    actual=Cross-project dependency issues detected in organization `${AZURE_DEVOPS_ORG}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${cross_deps.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    
    RW.Core.Add Pre To Report    Cross-Project Dependencies Analysis:
    RW.Core.Add Pre To Report    ${cross_deps.stdout}

Investigate Platform Issues for Organization `${AZURE_DEVOPS_ORG}`
    [Documentation]    Performs detailed investigation of agent pool issues and analyzes recent pipeline failures across all projects.
    [Tags]    Organization    Investigation    Platform    Performance    access:read-only    data:logs-bulk
    
    ${platform_investigation}=    RW.CLI.Run Bash File
    ...    bash_file=platform-issue-investigation.sh
    ...    env=${env}
    ...    secret__azure_devops_pat=${AZURE_DEVOPS_PAT}
    ...    timeout_seconds=600
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat platform_issue_investigation.json
    
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to load platform issues JSON payload — the script likely timed out or the API was unreachable.    WARN
        ${issue_list}=    Create List
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Platform issue investigation data should be collected successfully from Azure DevOps API for organization `${AZURE_DEVOPS_ORG}`
        ...    actual=Failed to collect platform investigation data — the script likely timed out or the Azure DevOps API was unreachable
        ...    title=Platform Investigation Data Collection Failed for `${AZURE_DEVOPS_ORG}`
        ...    reproduce_hint=${platform_investigation.cmd}
        ...    details=The platform-issue-investigation.sh script did not produce valid JSON output. This typically indicates the Azure DevOps API was unresponsive or the script exceeded its ${{'600'}}s timeout while scanning organization agent pools.\n\nStdout: ${platform_investigation.stdout}
        ...    next_steps=If this recurs, raise the task timeout or lower MAX_POOLS to bound the scan. Check Azure DevOps API availability and the identity's Agent Pools (Read) scope.
    END
    
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Platform should be operating optimally for organization `${AZURE_DEVOPS_ORG}`
            ...    actual=Platform issues detected affecting organization `${AZURE_DEVOPS_ORG}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${platform_investigation.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    
    RW.Core.Add Pre To Report    Platform Issue Investigation:
    RW.Core.Add Pre To Report    ${platform_investigation.stdout}


*** Keywords ***
Suite Initialization
    # Support both Azure Service Principal and Azure DevOps PAT authentication
    TRY
        ${azure_credentials}=    RW.Core.Import Secret
        ...    azure_credentials
        ...    type=string
        ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
        ...    pattern=\w*
        Set Suite Variable    ${AUTH_TYPE}    service_principal
        Set Suite Variable    ${AZURE_DEVOPS_PAT}    ${EMPTY}
    EXCEPT
        Log    Azure credentials not found, trying Azure DevOps PAT...    INFO
        TRY
            ${azure_devops_pat}=    RW.Core.Import Secret
            ...    azure_devops_pat
            ...    type=string
            ...    description=Azure DevOps Personal Access Token
            ...    pattern=\w*
            Set Suite Variable    ${AUTH_TYPE}    pat
            Set Suite Variable    ${AZURE_DEVOPS_PAT}    ${azure_devops_pat}
        EXCEPT
            Log    No authentication method found, defaulting to service principal...    WARN
            Set Suite Variable    ${AUTH_TYPE}    service_principal
            Set Suite Variable    ${AZURE_DEVOPS_PAT}    ${EMPTY}
        END
    END
    
    ${AZURE_DEVOPS_ORG}=    RW.Core.Import User Variable    AZURE_DEVOPS_ORG
    ...    type=string
    ...    description=Azure DevOps organization name.
    ...    pattern=\w*
    ${AGENT_UTILIZATION_THRESHOLD}=    RW.Core.Import User Variable    AGENT_UTILIZATION_THRESHOLD
    ...    type=string
    ...    description=Agent pool utilization threshold percentage (0-100) above which capacity issues are flagged.
    ...    default=80
    ...    pattern=\w*
    ${LICENSE_UTILIZATION_THRESHOLD}=    RW.Core.Import User Variable    LICENSE_UTILIZATION_THRESHOLD
    ...    type=string
    ...    description=License utilization threshold percentage (0-100) above which licensing issues are flagged.
    ...    default=90
    ...    pattern=\w*
    ${RW_LOOKBACK_WINDOW}=    RW.Core.Import User Variable    RW_LOOKBACK_WINDOW
    ...    type=string
    ...    description=Lookback window for time-windowed organization analyses. Format: 24h, 7d, 30d. Point-in-time signals (pool capacity, incidents) ignore it.
    ...    default=24h
    ...    pattern=\w*
    ${MAX_PROJECTS}=    RW.Core.Import User Variable    MAX_PROJECTS
    ...    type=string
    ...    description=Maximum number of projects scanned for cross-project dependency analysis (bounds runtime on large organizations).
    ...    default=25
    ...    pattern=\w*
    
    Set Suite Variable    ${AZURE_DEVOPS_ORG}    ${AZURE_DEVOPS_ORG}
    Set Suite Variable    ${AGENT_UTILIZATION_THRESHOLD}    ${AGENT_UTILIZATION_THRESHOLD}
    Set Suite Variable    ${LICENSE_UTILIZATION_THRESHOLD}    ${LICENSE_UTILIZATION_THRESHOLD}
    Set Suite Variable    ${RW_LOOKBACK_WINDOW}    ${RW_LOOKBACK_WINDOW}
    Set Suite Variable    ${MAX_PROJECTS}    ${MAX_PROJECTS}

    Set Suite Variable    ${AZURE_DEVOPS_CONFIG_DIR}    %{CODEBUNDLE_TEMP_DIR}/.azure-devops

    # Create the env dictionary for bash scripts
    ${env_dict}=    Create Dictionary
    ...    AZURE_DEVOPS_ORG=${AZURE_DEVOPS_ORG}
    ...    AGENT_UTILIZATION_THRESHOLD=${AGENT_UTILIZATION_THRESHOLD}
    ...    LICENSE_UTILIZATION_THRESHOLD=${LICENSE_UTILIZATION_THRESHOLD}
    ...    RW_LOOKBACK_WINDOW=${RW_LOOKBACK_WINDOW}
    ...    MAX_PROJECTS=${MAX_PROJECTS}
    ...    AUTH_TYPE=${AUTH_TYPE}
    ...    AZURE_CONFIG_DIR=${AZURE_DEVOPS_CONFIG_DIR}
    ...    AZURE_DEVOPS_CONFIG_DIR=${AZURE_DEVOPS_CONFIG_DIR}
    Set Suite Variable    ${env}    ${env_dict}

    # Preflight access check: probe each required capability and report exactly
    # which PAT scope / Azure DevOps role is missing when access is insufficient.
    Log    Running preflight access checks...    INFO
    ${preflight}=    RW.CLI.Run Bash File
    ...    bash_file=preflight-check.sh
    ...    env=${env}
    ...    secret__azure_devops_pat=${AZURE_DEVOPS_PAT}
    ...    timeout_seconds=120
    ...    include_in_history=false

    ${preflight_json_raw}=    RW.CLI.Run Cli
    ...    cmd=cat preflight_results.json 2>/dev/null || echo '{"summary": "Preflight results not available", "access_ok": false, "identity": {"name": "unknown"}}'

    TRY
        ${preflight_data}=    Evaluate    json.loads(r'''${preflight_json_raw.stdout}''')    json
        ${preflight_summary}=    Set Variable    ${preflight_data['summary']}
        # Prefer the script's full, actionable report (capability matrix + the
        # exact scope/role/endpoint remediation). Fall back to the raw stdout so
        # the matrix still reaches the issue even on an older results file.
        ${preflight_details}=    Evaluate    $preflight_data.get('report') or $preflight_data.get('summary') or r'''${preflight.stdout}'''
        Log    Preflight result: ${preflight_summary}    INFO
    EXCEPT
        Log    WARNING: Could not parse preflight results. Raw output: ${preflight.stdout}    WARN
        # Do NOT swallow this: a missing/invalid results file means the access
        # probe could not be recorded, so surface it as a real (access_ok=False)
        # finding and carry the raw probe output so it stays actionable.
        ${preflight_data}=    Evaluate    {"summary": "Preflight access check did not complete (results file missing or invalid)", "access_ok": False, "identity": {"name": "unknown"}}
        ${preflight_summary}=    Set Variable    Preflight access check did not complete (results file missing or invalid)
        ${preflight_details}=    Set Variable    ${preflight.stdout}
    END

    Set Suite Variable    ${PREFLIGHT_DATA}    ${preflight_data}
    Set Suite Variable    ${PREFLIGHT_SUMMARY}    ${preflight_summary}
    Set Suite Variable    ${PREFLIGHT_DETAILS}    ${preflight_details}

    RW.Core.Add Pre To Report    Preflight Access Check:
    RW.Core.Add Pre To Report    ${preflight.stdout} 