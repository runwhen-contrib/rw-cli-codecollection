*** Settings ***
Documentation       Comprehensive Azure DevOps organization health monitoring focusing on platform-wide issues and shared resources
Metadata            Author    runwhen
Metadata            Display Name    Azure DevOps Organization Health
Metadata            Supports    Azure    DevOps    Organization    Platform    Health
Force Tags          Azure    DevOps    Organization    Platform    Health

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check Service Health Status for Azure DevOps Organization `${AZURE_DEVOPS_ORG}`
    [Documentation]    Check the overall health status of Azure DevOps services for the organization
    [Tags]    Organization    Service    Health    Platform    access:read-only
    
    ${service_health}=    RW.CLI.Run Bash File
    ...    bash_file=organization-service-health.sh
    ...    env=${env}
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
    [Documentation]    Analyze agent pool capacity, utilization, and distribution across the organization
    [Tags]    Organization    AgentPools    Capacity    Distribution    access:read-only
    
    ${agent_capacity}=    RW.CLI.Run Bash File
    ...    bash_file=agent-pool-capacity.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat agent_pool_capacity.json
    
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to load agent capacity JSON payload, defaulting to empty list.    WARN
        ${issue_list}=    Create List
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
    [Documentation]    Verify organization-level policies, security settings, and compliance status
    [Tags]    Organization    Policies    Compliance    Security    access:read-only
    
    ${org_policies}=    RW.CLI.Run Bash File
    ...    bash_file=organization-policies.sh
    ...    env=${env}
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
    [Documentation]    Check license usage, capacity, and identify potential licensing issues
    [Tags]    Organization    Licenses    Capacity    Utilization    access:read-only
    
    ${license_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=license-utilization.sh
    ...    env=${env}
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
    [Documentation]    Check for platform-wide service incidents that might be affecting the organization
    [Tags]    Organization    Incidents    Platform    Service    access:read-only
    
    ${service_incidents}=    RW.CLI.Run Bash File
    ...    bash_file=service-incident-check.sh
    ...    env=${env}
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
    [Documentation]    Identify and analyze dependencies between projects that might impact overall organization health
    [Tags]    Organization    Dependencies    Projects    Integration    access:read-only
    
    ${cross_deps}=    RW.CLI.Run Bash File
    ...    bash_file=cross-project-dependencies.sh
    ...    env=${env}
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
    [Documentation]    Deep dive investigation for platform-wide issues affecting organization performance
    [Tags]    Organization    Investigation    Platform    Performance    access:read-only
    
    ${platform_investigation}=    RW.CLI.Run Bash File
    ...    bash_file=platform-issue-investigation.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat platform_issues.json
    
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to load platform issues JSON payload, defaulting to empty list.    WARN
        ${issue_list}=    Create List
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
    EXCEPT
        Log    Azure credentials not found, trying Azure DevOps PAT...    INFO
        TRY
            ${azure_devops_pat}=    RW.Core.Import Secret
            ...    azure_devops_pat
            ...    type=string
            ...    description=Azure DevOps Personal Access Token
            ...    pattern=\w*
            Set Suite Variable    ${AUTH_TYPE}    pat
        EXCEPT
            Log    No authentication method found, defaulting to service principal...    WARN
            Set Suite Variable    ${AUTH_TYPE}    service_principal
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
    
    Set Suite Variable    ${AZURE_DEVOPS_ORG}    ${AZURE_DEVOPS_ORG}
    Set Suite Variable    ${AGENT_UTILIZATION_THRESHOLD}    ${AGENT_UTILIZATION_THRESHOLD}
    Set Suite Variable    ${LICENSE_UTILIZATION_THRESHOLD}    ${LICENSE_UTILIZATION_THRESHOLD}
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_DEVOPS_ORG":"${AZURE_DEVOPS_ORG}", "AGENT_UTILIZATION_THRESHOLD":"${AGENT_UTILIZATION_THRESHOLD}", "LICENSE_UTILIZATION_THRESHOLD":"${LICENSE_UTILIZATION_THRESHOLD}", "AUTH_TYPE":"${AUTH_TYPE}"} 