*** Settings ***
Documentation       Check Azure DevOps health by examining pipeline status, agent pools, and build logs
Metadata            Author    saurabh3460
Metadata            Display Name    Azure DevOps Triage
Metadata            Supports    Azure    DevOps    Pipelines    Health
Force Tags          Azure    DevOps    Pipelines    Health

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check Agent pool availability in organisation `${AZURE_DEVOPS_ORG}` in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Check the health status of Agent Pools in the specified organization
    [Tags]    DevOps    Azure    Health    access:read-only
    ${agent_pool}=    RW.CLI.Run Bash File
    ...    bash_file=agent-pools.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat agent_pools_issues.json    

    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json

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

Check for Failed Pipelines in project `${AZURE_DEVOPS_PROJECT}` in organisation `${AZURE_DEVOPS_ORG}`
    [Documentation]    Identify failed pipeline runs in the specified project
    [Tags]    DevOps    Azure    Pipelines    Failures    access:read-only
    ${failed_pipelines}=    RW.CLI.Run Bash File
    ...    bash_file=pipeline-logs.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    RW.Core.Add Pre To Report    ${failed_pipelines.stdout}
    
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat pipeline_logs_issues.json
    
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Pipeline should complete successfully
            ...    actual=Pipeline failed with errors
            ...    title=${issue['title']}
            ...    reproduce_hint=${failed_pipelines.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_step']}
            ...    resource_url=${issue['resource_url']}
        END
    END

Check for Long Running Pipelines in project `${AZURE_DEVOPS_PROJECT}` in organisation `${AZURE_DEVOPS_ORG}` (Threshold: ${DURATION_THRESHOLD})
    [Documentation]    Identify pipelines that are running longer than expected
    [Tags]    DevOps    Azure    Pipelines    Performance    access:read-only
    ${long_running}=    RW.CLI.Run Bash File
    ...    bash_file=long-running-pipelines.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    RW.Core.Add Pre To Report    ${long_running.stdout}
    
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat long_running_pipelines.json
    
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Pipeline should complete within the expected time frame (${DURATION_THRESHOLD})
            ...    actual=Pipeline is running longer than expected (${issue['duration']})
            ...    title=${issue['title']}
            ...    reproduce_hint=${long_running.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_step']}
            ...    resource_url=${issue['resource_url']}
        END
    END

Check for Queued Pipelines in project `${AZURE_DEVOPS_PROJECT}` in organisation `${AZURE_DEVOPS_ORG}` (Threshold: ${QUEUE_THRESHOLD})
    [Documentation]    Identify pipelines that are queued for longer than expected
    [Tags]    DevOps    Azure    Pipelines    Queue    access:read-only
    ${queued_pipelines}=    RW.CLI.Run Bash File
    ...    bash_file=queued-pipelines.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    RW.Core.Add Pre To Report    ${queued_pipelines.stdout}
    
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat queued_pipelines.json
    
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Pipeline should start execution promptly (within ${QUEUE_THRESHOLD})
            ...    actual=Pipeline has been queued for ${issue['queue_time']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${queued_pipelines.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_step']}
            ...    resource_url=${issue['resource_url']}
        END
    END

Check for Repository Policy Issues in project `${AZURE_DEVOPS_PROJECT}` in organisation `${AZURE_DEVOPS_ORG}`
    [Documentation]    Verify repository branch policies against best practices
    [Tags]    DevOps    Azure    Repository    Policies    access:read-only
    ${repo_policies}=    RW.CLI.Run Bash File
    ...    bash_file=repo-policies.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    RW.Core.Add Pre To Report    ${repo_policies.stdout}
    
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat repo_policies_issues.json
    
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Repository should have proper branch policies configured
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${repo_policies.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_step']}
        END
    END

Check for Service Connection Issues in project `${AZURE_DEVOPS_PROJECT}` in organisation `${AZURE_DEVOPS_ORG}`
    [Documentation]    Verify the health of service connections used by pipelines
    [Tags]    DevOps    Azure    ServiceConnections    access:read-only
    ${service_connections}=    RW.CLI.Run Bash File
    ...    bash_file=service-connections.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    RW.Core.Add Pre To Report    ${service_connections.stdout}
    
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat service_connections_issues.json
    
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Service connections should be healthy and accessible
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${service_connections.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_step']}
        END
    END

*** Keywords ***
Suite Initialization
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    ${AZURE_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZURE_RESOURCE_GROUP
    ...    type=string
    ...    description=Azure resource group.
    ...    pattern=\w*
    ${AZURE_DEVOPS_ORG}=    RW.Core.Import User Variable    AZURE_DEVOPS_ORG
    ...    type=string
    ...    description=Azure DevOps organization.
    ...    pattern=\w*
    ${AZURE_DEVOPS_PROJECT}=    RW.Core.Import User Variable    AZURE_DEVOPS_PROJECT
    ...    type=string
    ...    description=Azure DevOps project.
    ...    pattern=\w*
    ${DAYS_TO_LOOK_BACK}=    RW.Core.Import User Variable    DAYS_TO_LOOK_BACK
    ...    type=integer
    ...    description=Number of days to look back for pipeline runs
    ...    default=7
    ${DURATION_THRESHOLD}=    RW.Core.Import User Variable    DURATION_THRESHOLD
    ...    type=string
    ...    description=Threshold for long-running pipelines (format: 60m, 2h)
    ...    default=60m
    ${QUEUE_THRESHOLD}=    RW.Core.Import User Variable    QUEUE_THRESHOLD
    ...    type=string
    ...    description=Threshold for queued pipelines (format: 10m, 1h)
    ...    default=10m
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${AZURE_DEVOPS_ORG}    ${AZURE_DEVOPS_ORG}
    Set Suite Variable    ${AZURE_DEVOPS_PROJECT}    ${AZURE_DEVOPS_PROJECT}
    Set Suite Variable    ${DAYS_TO_LOOK_BACK}    ${DAYS_TO_LOOK_BACK}
    Set Suite Variable    ${DURATION_THRESHOLD}    ${DURATION_THRESHOLD}
    Set Suite Variable    ${QUEUE_THRESHOLD}    ${QUEUE_THRESHOLD}
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_DEVOPS_ORG":"${AZURE_DEVOPS_ORG}", "AZURE_DEVOPS_PROJECT":"${AZURE_DEVOPS_PROJECT}", "DAYS_TO_LOOK_BACK":"${DAYS_TO_LOOK_BACK}", "DURATION_THRESHOLD":"${DURATION_THRESHOLD}", "QUEUE_THRESHOLD":"${QUEUE_THRESHOLD}"}
