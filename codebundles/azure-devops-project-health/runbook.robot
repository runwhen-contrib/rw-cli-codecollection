*** Settings ***
Documentation       Comprehensive Azure DevOps project health monitoring with conditional deep investigation
Metadata            Author    runwhen
Metadata            Display Name    Azure DevOps Project Health
Metadata            Supports    Azure    DevOps    Projects    Health
Force Tags          Azure    DevOps    Projects    Health

Library             String
Library             BuiltIn
Library             Collections
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check Agent Pool Availability for Organization `${AZURE_DEVOPS_ORG}`
    [Documentation]    Check agent pool health and capacity issues
    [Tags]    DevOps    Azure    Health    access:read-only
    
    ${project_count}=    Get Length    ${PROJECT_LIST}
    Log    Starting agent pool check for ${project_count} projects: ${PROJECT_LIST}    INFO
    
    ${agent_pool}=    RW.CLI.Run Bash File
    ...    bash_file=agent-pools.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat agent_pools_issues.json    

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to load agent pool JSON payload, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${agent}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${agent['severity']}
                ...    expected=Agent Pool should be available in organization `${AZURE_DEVOPS_ORG}`
                ...    actual=Agent Pool is unhealthy in organization `${AZURE_DEVOPS_ORG}`
                ...    title=Azure DevOps reports an Issue for Agent Pool in organization `${AZURE_DEVOPS_ORG}`
                ...    reproduce_hint=${agent_pool.cmd}
                ...    details=${agent}
                ...    next_steps=Please escalate to the Azure DevOps service owner or check back later.
        END
   END
   
    RW.Core.Add Pre To Report    Agent Pool Status:
    RW.Core.Add Pre To Report    ${agent_pool.stdout}

Check for Failed Pipelines Across Projects in Organization `${AZURE_DEVOPS_ORG}`
    [Documentation]    Identify failed pipeline runs with detailed logs
    [Tags]    DevOps    Azure    Pipelines    Failures    access:read-only
    
    ${project_count}=    Get Length    ${PROJECT_LIST}
    Log    Checking failed pipelines across ${project_count} projects: ${PROJECT_LIST}    INFO
    
    FOR    ${project}    IN    @{PROJECT_LIST}
        Log    Checking failed pipelines for project: ${project}    INFO
        
        # Validate project name is not empty
        IF    "${project.strip()}" == ""
            Log    Skipping empty project name    WARN
            CONTINUE
        END
        
        ${failed_pipelines}=    RW.CLI.Run Bash File
        ...    bash_file=pipeline-logs.sh
        ...    env=${env}
        ...    timeout_seconds=180
        ...    include_in_history=false
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=AZURE_DEVOPS_PROJECT="${project}" ./pipeline-logs.sh
        
        RW.Core.Add Pre To Report    Failed Pipelines for Project ${project}:
        RW.Core.Add Pre To Report    ${failed_pipelines.stdout}
        
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat pipeline_logs_issues.json
        
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        EXCEPT
            Log    Failed to load JSON payload for project ${project}, defaulting to empty list.    WARN
            ${issue_list}=    Create List
        END
        
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=Pipeline should complete successfully in project `${project}`
                ...    actual=Pipeline failed with errors in project `${project}`
                ...    title=${issue['title']} (Project: ${project})
                ...    reproduce_hint=${failed_pipelines.cmd}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_step']}
                ...    resource_url=${issue['resource_url']}
            END
        END
    END

Check for Long-Running Pipelines in Organization `${AZURE_DEVOPS_ORG}` (Threshold: ${DURATION_THRESHOLD})
    [Documentation]    Identify pipelines exceeding duration thresholds
    [Tags]    DevOps    Azure    Pipelines    Performance    access:read-only
    FOR    ${project}    IN    @{PROJECT_LIST}
        Log    Checking long running pipelines for project: ${project}
        ${long_running}=    RW.CLI.Run Bash File
        ...    bash_file=long-running-pipelines.sh
        ...    env=${env}
        ...    timeout_seconds=180
        ...    include_in_history=false
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=AZURE_DEVOPS_PROJECT="${project}" ./long-running-pipelines.sh
        
        RW.Core.Add Pre To Report    Long Running Pipelines for Project ${project}:
        RW.Core.Add Pre To Report    ${long_running.stdout}
        
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat long_running_pipelines.json
        
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        EXCEPT
            Log    Failed to load JSON payload for project ${project}, defaulting to empty list.    WARN
            ${issue_list}=    Create List
        END
        
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=Pipeline should complete within the expected time frame (${DURATION_THRESHOLD}) in project `${project}`
                ...    actual=Pipeline is running longer than expected (${issue['duration']}) in project `${project}`
                ...    title=${issue['title']} (Project: ${project})
                ...    reproduce_hint=${long_running.cmd}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_step']}
                ...    resource_url=${issue['resource_url']}
            END
        END
    END

Check for Queued Pipelines in Organization `${AZURE_DEVOPS_ORG}` (Threshold: ${QUEUE_THRESHOLD})
    [Documentation]    Identify pipelines queued beyond threshold limits
    [Tags]    DevOps    Azure    Pipelines    Queue    access:read-only
    FOR    ${project}    IN    @{PROJECT_LIST}
        Log    Checking queued pipelines for project: ${project}
        ${queued_pipelines}=    RW.CLI.Run Bash File
        ...    bash_file=queued-pipelines.sh
        ...    env=${env}
        ...    timeout_seconds=180
        ...    include_in_history=false
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=AZURE_DEVOPS_PROJECT="${project}" ./queued-pipelines.sh
        
        RW.Core.Add Pre To Report    Queued Pipelines for Project ${project}:
        RW.Core.Add Pre To Report    ${queued_pipelines.stdout}
        
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat queued_pipelines.json
        
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        EXCEPT
            Log    Failed to load JSON payload for project ${project}, defaulting to empty list.    WARN
            ${issue_list}=    Create List
        END
        
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=Pipeline should start execution promptly (within ${QUEUE_THRESHOLD}) in project `${project}`
                ...    actual=Pipeline has been queued for ${issue['queue_time']} in project `${project}`
                ...    title=${issue['title']} (Project: ${project})
                ...    reproduce_hint=${queued_pipelines.cmd}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_step']}
                ...    resource_url=${issue['resource_url']}
            END
        END
    END

Check Repository Branch Policies Across Projects in Organization `${AZURE_DEVOPS_ORG}`
    [Documentation]    Verify repository branch policies compliance
    [Tags]    DevOps    Azure    Repository    Policies    access:read-only
    FOR    ${project}    IN    @{PROJECT_LIST}
        Log    Checking repository policies for project: ${project}
        ${repo_policies}=    RW.CLI.Run Bash File
        ...    bash_file=repo-policies.sh
        ...    env=${env}
        ...    timeout_seconds=180
        ...    include_in_history=false
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=AZURE_DEVOPS_PROJECT="${project}" ./repo-policies.sh
        
        RW.Core.Add Pre To Report    Repository Policies for Project ${project}:
        RW.Core.Add Pre To Report    ${repo_policies.stdout}
        
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat repo_policies_issues.json
        
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        EXCEPT
            Log    Failed to load JSON payload for project ${project}, defaulting to empty list.    WARN
            ${issue_list}=    Create List
        END
        
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=Repository policies should follow best practices in project `${project}`
                ...    actual=Repository policy violations detected in project `${project}`
                ...    title=${issue['title']} (Project: ${project})
                ...    reproduce_hint=${repo_policies.cmd}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_step']}
            END
        END
    END

Check Service Connection Health Across Projects in Organization `${AZURE_DEVOPS_ORG}`
    [Documentation]    Verify service connection availability and readiness
    [Tags]    DevOps    Azure    ServiceConnections    access:read-only
    FOR    ${project}    IN    @{PROJECT_LIST}
        Log    Checking service connections for project: ${project}
        ${service_connections}=    RW.CLI.Run Bash File
        ...    bash_file=service-connections.sh
        ...    env=${env}
        ...    timeout_seconds=180
        ...    include_in_history=false
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=AZURE_DEVOPS_PROJECT="${project}" ./service-connections.sh
        
        RW.Core.Add Pre To Report    Service Connections for Project ${project}:
        RW.Core.Add Pre To Report    ${service_connections.stdout}
        
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat service_connections_issues.json
        
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        EXCEPT
            Log    Failed to load JSON payload for project ${project}, defaulting to empty list.    WARN
            ${issue_list}=    Create List
        END
        
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=Service connections should be healthy and accessible in project `${project}`
                ...    actual=${issue['details']} in project `${project}`
                ...    title=${issue['title']} (Project: ${project})
                ...    reproduce_hint=${service_connections.cmd}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_step']}
            END
        END
    END

Investigate Pipeline Performance Issues for Organization `${AZURE_DEVOPS_ORG}`
    [Documentation]    Analyze pipeline performance trends and bottlenecks
    [Tags]    Investigation    Performance    Trends    Bottlenecks    access:read-only
    
    FOR    ${project}    IN    @{PROJECT_LIST}
        Log    Analyzing performance trends for project: ${project}
        
        ${performance_analysis}=    RW.CLI.Run Bash File
        ...    bash_file=pipeline-performance-analysis.sh
        ...    env=${env}
        ...    timeout_seconds=180
        ...    include_in_history=false
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=AZURE_DEVOPS_PROJECT="${project}" ./pipeline-performance-analysis.sh
        
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat pipeline_performance_issues.json
        
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        EXCEPT
            Log    Failed to load JSON payload for project ${project}, defaulting to empty list.    WARN
            ${issue_list}=    Create List
        END
        
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=Pipeline performance should be optimal in project `${project}`
                ...    actual=Performance issues detected in project `${project}`
                ...    title=${issue['title']} (Project: ${project})
                ...    reproduce_hint=${performance_analysis.cmd}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_steps']}
            END
        END
        
        RW.Core.Add Pre To Report    Performance Analysis for Project ${project}:
        RW.Core.Add Pre To Report    ${performance_analysis.stdout}
    END




*** Keywords ***
Suite Initialization
    Log    Starting Suite Initialization...    INFO
    
    # Support both Azure Service Principal and Azure DevOps PAT authentication
    Log    Setting up authentication...    INFO
    TRY
        ${azure_credentials}=    RW.Core.Import Secret
        ...    azure_credentials
        ...    type=string
        ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
        ...    pattern=\w*
        Set Suite Variable    ${AUTH_TYPE}    service_principal
        Log    Using service principal authentication    INFO
    EXCEPT
        Log    Azure credentials not found, trying Azure DevOps PAT...    INFO
        TRY
            ${azure_devops_pat}=    RW.Core.Import Secret
            ...    azure_devops_pat
            ...    type=string
            ...    description=Azure DevOps Personal Access Token
            ...    pattern=\w*
            Set Suite Variable    ${AUTH_TYPE}    pat
            Log    Using PAT authentication    INFO
        EXCEPT
            Log    No authentication method found, defaulting to service principal...    WARN
            Set Suite Variable    ${AUTH_TYPE}    service_principal
        END
    END
    
    Log    Importing user variables...    INFO
    ${AZURE_DEVOPS_ORG}=    RW.Core.Import User Variable    AZURE_DEVOPS_ORG
    ...    type=string
    ...    description=Azure DevOps organization name.
    ...    pattern=\w*
    
    ${AZURE_DEVOPS_PROJECTS}=    RW.Core.Import User Variable    AZURE_DEVOPS_PROJECTS
    ...    type=string
    ...    description=Comma-separated list of Azure DevOps projects to monitor (e.g., "project1,project2,project3") or "All" to monitor all projects.
    ...    pattern=.*
    ...    default=All
    Log    AZURE_DEVOPS_PROJECTS: ${AZURE_DEVOPS_PROJECTS}    INFO
    
    ${DURATION_THRESHOLD}=    RW.Core.Import User Variable    DURATION_THRESHOLD
    ...    type=string
    ...    description=Threshold for long-running pipelines (format: 60m, 2h)
    ...    default=60m
    ...    pattern=\w*
    ${QUEUE_THRESHOLD}=    RW.Core.Import User Variable    QUEUE_THRESHOLD
    ...    type=string
    ...    description=Threshold for queued pipelines (format: 10m, 1h)
    ...    default=30m
    ...    pattern=\w*
    
    Log    Processing project list...    INFO
    # Handle project list - either "All" or explicit CSV list
    ${projects_all}=    Evaluate    "${AZURE_DEVOPS_PROJECTS}".strip().lower() == "all"
    
    IF    ${projects_all}
        Log    Auto-discovering all projects in organization...    INFO
        ${PROJECT_LIST}=    Discover All Projects
    ELSE
        Log    Processing provided project list: ${AZURE_DEVOPS_PROJECTS}    INFO
        # Convert comma-separated projects to list and clean up
        ${PROJECT_LIST}=    Split String    ${AZURE_DEVOPS_PROJECTS}    ,
        ${cleaned_projects}=    Create List
        FOR    ${project}    IN    @{PROJECT_LIST}
            ${project_trimmed}=    Strip String    ${project}
            IF    "${project_trimmed}" != ""
                Append To List    ${cleaned_projects}    ${project_trimmed}
            END
        END
        ${PROJECT_LIST}=    Set Variable    ${cleaned_projects}
        
        # Validate that we have at least one project after cleanup
        ${project_count}=    Get Length    ${PROJECT_LIST}
        IF    ${project_count} == 0
            Fail    No valid projects found in the provided list. Please provide either "All" or a comma-separated list of project names.
        END
    END
    
    # Final validation
    ${project_count}=    Get Length    ${PROJECT_LIST}
    IF    ${project_count} == 0
        Fail    No projects found or accessible. Check organization name and permissions.
    END
    
    Log    Will monitor ${project_count} projects: ${PROJECT_LIST}    INFO
    
    Log    Setting suite variables...    INFO
    Set Suite Variable    ${AZURE_DEVOPS_ORG}    ${AZURE_DEVOPS_ORG}
    Set Suite Variable    ${PROJECT_LIST}    ${PROJECT_LIST}
    Set Suite Variable    ${DURATION_THRESHOLD}    ${DURATION_THRESHOLD}
    Set Suite Variable    ${QUEUE_THRESHOLD}    ${QUEUE_THRESHOLD}

    Set Suite Variable    ${AZURE_DEVOPS_CONFIG_DIR}    %{CODEBUNDLE_TEMP_DIR}/.azure-devops

    # Create the env dictionary for bash scripts
    ${env_dict}=    Create Dictionary
    ...    AZURE_DEVOPS_ORG=${AZURE_DEVOPS_ORG}
    ...    DURATION_THRESHOLD=${DURATION_THRESHOLD}
    ...    QUEUE_THRESHOLD=${QUEUE_THRESHOLD}
    ...    AUTH_TYPE=${AUTH_TYPE}
    ...    AZURE_CONFIG_DIR=${AZURE_DEVOPS_CONFIG_DIR}
    Set Suite Variable    ${env}    ${env_dict}
    
    Log    Suite Initialization completed successfully!    INFO


Discover All Projects
    [Documentation]    Auto-discover all projects in the Azure DevOps organization
    
    # Create a temporary env dictionary for this discovery call
    ${temp_env}=    Create Dictionary
    ...    AZURE_DEVOPS_ORG=${AZURE_DEVOPS_ORG}
    ...    AUTH_TYPE=${AUTH_TYPE}
    
    ${discover_projects}=    RW.CLI.Run Bash File
    ...    bash_file=discover-projects.sh
    ...    env=${temp_env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    
    ${projects_result}=    RW.CLI.Run Cli
    ...    cmd=cat discovered_projects.json
    
    TRY
        ${projects_data}=    Evaluate    json.loads(r'''${projects_result.stdout}''')    json
        ${project_names}=    Evaluate    [project['name'] for project in ${projects_data}]
        RETURN    ${project_names}
    EXCEPT
        Log    Failed to discover projects, using fallback method...    WARN
        # Fallback: try to extract from stdout
        ${project_lines}=    Split To Lines    ${discover_projects.stdout}
        ${project_names}=    Create List
        FOR    ${line}    IN    @{project_lines}
            ${line}=    Strip String    ${line}
            IF    "${line}" != "" and not "${line}".startswith("#") and not "${line}".startswith("Analyzing")
                Append To List    ${project_names}    ${line}
            END
        END
        RETURN    ${project_names}
    END
