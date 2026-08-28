*** Settings ***
Documentation       Counts Azure DevOps health issues by examining pipeline status, agent pools, and build logs
Metadata            Author    Nbarola
Metadata            Display Name    Azure DevOps Health
Metadata            Supports    Azure    DevOps    Pipelines    Health
Force Tags          Azure    DevOps    Pipelines    Health

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization

*** Tasks ***
Count Agent Pool Health Issues in organisation `${AZURE_DEVOPS_ORG}`
    [Documentation]    Counts the health issues of Agent Pools in the specified organization
    [Tags]    DevOps    Azure    Health    access:read-only
    ${agent_pool}=    RW.CLI.Run Bash File
    ...    bash_file=agent-pools.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(open('agent_pools_issues.json').read())    json
    EXCEPT
        Log    Failed to load JSON file, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    ${issue_count}=    Get Length    ${issue_list}
    ${agent_pool_health_score}=    Evaluate    1 if ${issue_count} == 0 else 0
    Set Global Variable    ${agent_pool_health_score}

Count Failed Pipeline Runs in project `${AZURE_DEVOPS_PROJECT}` in organisation `${AZURE_DEVOPS_ORG}`
    [Documentation]    Counts the number of failed pipeline runs in the specified project
    [Tags]    DevOps    Azure    Pipelines    Failures    access:read-only
    ${failed_pipelines}=    RW.CLI.Run Bash File
    ...    bash_file=pipeline-logs.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(open('pipeline_logs_issues.json').read())    json
    EXCEPT
        Log    Failed to load JSON file, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    ${issue_count}=    Get Length    ${issue_list}
    ${failed_pipelines_score}=    Evaluate    1 if ${issue_count} == 0 else 0
    Set Global Variable    ${failed_pipelines_score}

Count Long Running Pipelines in project `${AZURE_DEVOPS_PROJECT}` in organisation `${AZURE_DEVOPS_ORG}`
    [Documentation]    Counts pipelines that are running longer than expected
    [Tags]    DevOps    Azure    Pipelines    Performance    access:read-only
    ${long_running}=    RW.CLI.Run Bash File
    ...    bash_file=long-running-pipelines.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(open('long_running_pipelines.json').read())    json
    EXCEPT
        Log    Failed to load JSON file, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    ${issue_count}=    Get Length    ${issue_list}
    ${long_running_score}=    Evaluate    1 if ${issue_count} == 0 else 0
    Set Global Variable    ${long_running_score}

Count Queued Pipelines in project `${AZURE_DEVOPS_PROJECT}` in organisation `${AZURE_DEVOPS_ORG}`
    [Documentation]    Counts pipelines that are queued for longer than expected
    [Tags]    DevOps    Azure    Pipelines    Queue    access:read-only
    ${queued_pipelines}=    RW.CLI.Run Bash File
    ...    bash_file=queued-pipelines.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(open('queued_pipelines.json').read())    json
    EXCEPT
        Log    Failed to load JSON file, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    ${issue_count}=    Get Length    ${issue_list}
    ${queued_pipelines_score}=    Evaluate    1 if ${issue_count} == 0 else 0
    Set Global Variable    ${queued_pipelines_score}

Count Repository Policy Issues in project `${AZURE_DEVOPS_PROJECT}` in organisation `${AZURE_DEVOPS_ORG}`
    [Documentation]    Counts repository branch policy issues against best practices
    [Tags]    DevOps    Azure    Pipelines    Policies    access:read-only
    ${repo_policy}=    RW.CLI.Run Bash File
    ...    bash_file=repo-policies.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(open('repo_policy_issues.json').read())    json
    EXCEPT
        Log    Failed to load JSON file, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    ${issue_count}=    Get Length    ${issue_list}
    ${repo_policy_score}=    Evaluate    1 if ${issue_count} == 0 else 0
    Set Global Variable    ${repo_policy_score}

Generate Comprehensive Azure DevOps Health Score
    ${devops_health_score}=    Evaluate    (${agent_pool_health_score} + ${failed_pipelines_score} + ${long_running_score} + ${queued_pipelines_score} + ${repo_policy_score}) / 5
    ${health_score}=    Convert to Number    ${devops_health_score}    2
    RW.Core.Push Metric    ${health_score}

*** Keywords ***
uite Initialization
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
    ${DURATION_THRESHOLD}=    RW.Core.Import User Variable    DURATION_THRESHOLD
    ...    type=string
    ...    description=Threshold for long-running pipelines (format: 60m, 2h)
    ...    default=60m
    ${QUEUE_THRESHOLD}=    RW.Core.Import User Variable    QUEUE_THRESHOLD
    ...    type=string
    ...    description=Threshold for queued pipelines (format: 10m, 1h)
    ...    default=30m
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${AZURE_DEVOPS_ORG}    ${AZURE_DEVOPS_ORG}
    Set Suite Variable    ${AZURE_DEVOPS_PROJECT}    ${AZURE_DEVOPS_PROJECT}
    Set Suite Variable    ${DURATION_THRESHOLD}    ${DURATION_THRESHOLD}
    Set Suite Variable    ${QUEUE_THRESHOLD}    ${QUEUE_THRESHOLD}
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_DEVOPS_ORG":"${AZURE_DEVOPS_ORG}", "AZURE_DEVOPS_PROJECT":"${AZURE_DEVOPS_PROJECT}", "DURATION_THRESHOLD":"${DURATION_THRESHOLD}", "QUEUE_THRESHOLD":"${QUEUE_THRESHOLD}"}
