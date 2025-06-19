*** Settings ***
Documentation       Repository health monitoring for Azure DevOps focusing on code quality, security, and configuration issues that impact development workflows, with specific tasks for troubleshooting failing applications
Metadata            Author    stewartshea
Metadata            Display Name    Azure DevOps Repository Health
Metadata            Supports    Azure    DevOps    Repository    CodeQuality    Security    Troubleshooting
Force Tags          Azure    DevOps    Repository    CodeQuality    Security

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Investigate Recent Code Changes for Repositories in Project `${AZURE_DEVOPS_PROJECT}`
    [Documentation]    Analyze recent commits, releases, and code changes that might be causing application failures
    [Tags]    Repository    Troubleshooting    RecentChanges    Commits    Releases    access:read-only
    
    FOR    ${repo}    IN    @{REPOSITORY_LIST}
        Log    Investigating recent changes for repository: ${repo}
        ${recent_changes}=    RW.CLI.Run Bash File
        ...    bash_file=recent-changes-analysis.sh
        ...    env=${env}
        ...    timeout_seconds=180
        ...    include_in_history=false
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=AZURE_DEVOPS_REPO="${repo}" ./recent-changes-analysis.sh
        
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat recent_changes_analysis.json
        
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        EXCEPT
            Log    Failed to load recent changes JSON payload for repository ${repo}, defaulting to empty list.    WARN
            ${issue_list}=    Create List
        END
        
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=Recent changes should not introduce breaking changes without proper testing in repository `${repo}`
                ...    actual=Potentially problematic recent changes detected in repository `${repo}`
                ...    title=${issue['title']} (Repository: ${repo})
                ...    reproduce_hint=${recent_changes.cmd}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_steps']}
            END
        END
        
        RW.Core.Add Pre To Report    Recent Changes Analysis for Repository ${repo}:
        RW.Core.Add Pre To Report    ${recent_changes.stdout}
    END

Analyze Pipeline Failures for Repositories in Project `${AZURE_DEVOPS_PROJECT}`
    [Documentation]    Review recent CI/CD pipeline failures that might be affecting application deployments
    [Tags]    Repository    Troubleshooting    Pipelines    CI/CD    Failures    access:read-only
    
    FOR    ${repo}    IN    @{REPOSITORY_LIST}
        Log    Analyzing pipeline failures for repository: ${repo}
        ${pipeline_failures}=    RW.CLI.Run Bash File
        ...    bash_file=pipeline-failure-analysis.sh
        ...    env=${env}
        ...    timeout_seconds=180
        ...    include_in_history=false
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=AZURE_DEVOPS_REPO="${repo}" ./pipeline-failure-analysis.sh
        
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat pipeline_failure_analysis.json
        
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        EXCEPT
            Log    Failed to load pipeline failures JSON payload for repository ${repo}, defaulting to empty list.    WARN
            ${issue_list}=    Create List
        END
        
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=CI/CD pipelines should consistently succeed for stable deployments in repository `${repo}`
                ...    actual=Pipeline failures detected that may be preventing successful deployments in repository `${repo}`
                ...    title=${issue['title']} (Repository: ${repo})
                ...    reproduce_hint=${pipeline_failures.cmd}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_steps']}
            END
        END
        
        RW.Core.Add Pre To Report    Pipeline Failures Analysis for Repository ${repo}:
        RW.Core.Add Pre To Report    ${pipeline_failures.stdout}
    END

Check Repository Security Configuration for Repositories in Project `${AZURE_DEVOPS_PROJECT}`
    [Documentation]    Check repository security settings, branch policies, and access controls for misconfigurations
    [Tags]    Repository    Security    Configuration    BranchPolicies    access:read-only
    
    FOR    ${repo}    IN    @{REPOSITORY_LIST}
        Log    Checking security configuration for repository: ${repo}
        ${security_analysis}=    RW.CLI.Run Bash File
        ...    bash_file=repository-security-analysis.sh
        ...    env=${env}
        ...    timeout_seconds=180
        ...    include_in_history=false
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=AZURE_DEVOPS_REPO="${repo}" ./repository-security-analysis.sh
        
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat repository_security_analysis.json
        
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        EXCEPT
            Log    Failed to load repository security JSON payload for repository ${repo}, defaulting to empty list.    WARN
            ${issue_list}=    Create List
        END
        
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=Repository security should be properly configured in project `${AZURE_DEVOPS_PROJECT}`
                ...    actual=Security configuration issues detected in repository `${repo}`
                ...    title=${issue['title']} (Repository: ${repo})
                ...    reproduce_hint=${security_analysis.cmd}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_steps']}
            END
        END
        
        RW.Core.Add Pre To Report    Repository Security Analysis for ${repo}:
        RW.Core.Add Pre To Report    ${security_analysis.stdout}
    END

Analyze Code Quality for Repositories in Project `${AZURE_DEVOPS_PROJECT}`
    [Documentation]    Analyze repository for code quality issues, technical debt, and maintainability problems
    [Tags]    Repository    CodeQuality    TechnicalDebt    Maintainability    access:read-only
    
    FOR    ${repo}    IN    @{REPOSITORY_LIST}
        Log    Analyzing code quality for repository: ${repo}
        ${quality_analysis}=    RW.CLI.Run Bash File
        ...    bash_file=code-quality-analysis.sh
        ...    env=${env}
        ...    timeout_seconds=240
        ...    include_in_history=false
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=AZURE_DEVOPS_REPO="${repo}" ./code-quality-analysis.sh
        
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat code_quality_analysis.json
        
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        EXCEPT
            Log    Failed to load code quality JSON payload for repository ${repo}, defaulting to empty list.    WARN
            ${issue_list}=    Create List
        END
        
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=Code quality should meet standards in repository `${repo}`
                ...    actual=Code quality issues detected in repository `${repo}`
                ...    title=${issue['title']} (Repository: ${repo})
                ...    reproduce_hint=${quality_analysis.cmd}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_steps']}
            END
        END
        
        RW.Core.Add Pre To Report    Code Quality Analysis for ${repo}:
        RW.Core.Add Pre To Report    ${quality_analysis.stdout}
    END

Check Branch Management for Repositories in Project `${AZURE_DEVOPS_PROJECT}`
    [Documentation]    Analyze branch structure, stale branches, and merge patterns that indicate workflow issues
    [Tags]    Repository    BranchManagement    Workflow    GitFlow    access:read-only
    
    FOR    ${repo}    IN    @{REPOSITORY_LIST}
        Log    Checking branch management for repository: ${repo}
        ${branch_analysis}=    RW.CLI.Run Bash File
        ...    bash_file=branch-management-analysis.sh
        ...    env=${env}
        ...    timeout_seconds=180
        ...    include_in_history=false
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=AZURE_DEVOPS_REPO="${repo}" ./branch-management-analysis.sh
        
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat branch_management_analysis.json
        
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        EXCEPT
            Log    Failed to load branch management JSON payload for repository ${repo}, defaulting to empty list.    WARN
            ${issue_list}=    Create List
        END
        
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=Branch management should follow best practices in repository `${repo}`
                ...    actual=Branch management issues detected in repository `${repo}`
                ...    title=${issue['title']} (Repository: ${repo})
                ...    reproduce_hint=${branch_analysis.cmd}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_steps']}
            END
        END
        
        RW.Core.Add Pre To Report    Branch Management Analysis for ${repo}:
        RW.Core.Add Pre To Report    ${branch_analysis.stdout}
    END

Analyze Pull Request and Collaboration Patterns for Repositories in Project `${AZURE_DEVOPS_PROJECT}`
    [Documentation]    Examine PR review patterns, contributor activity, and collaboration health indicators
    [Tags]    Repository    PullRequests    Collaboration    CodeReview    access:read-only
    
    FOR    ${repo}    IN    @{REPOSITORY_LIST}
        Log    Analyzing collaboration patterns for repository: ${repo}
        ${collaboration_analysis}=    RW.CLI.Run Bash File
        ...    bash_file=collaboration-analysis.sh
        ...    env=${env}
        ...    timeout_seconds=180
        ...    include_in_history=false
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=AZURE_DEVOPS_REPO="${repo}" ./collaboration-analysis.sh
        
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat collaboration_analysis.json
        
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        EXCEPT
            Log    Failed to load collaboration JSON payload for repository ${repo}, defaulting to empty list.    WARN
            ${issue_list}=    Create List
        END
        
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=Collaboration patterns should be healthy in repository `${repo}`
                ...    actual=Collaboration issues detected in repository `${repo}`
                ...    title=${issue['title']} (Repository: ${repo})
                ...    reproduce_hint=${collaboration_analysis.cmd}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_steps']}
            END
        END
        
        RW.Core.Add Pre To Report    Collaboration Patterns Analysis for ${repo}:
        RW.Core.Add Pre To Report    ${collaboration_analysis.stdout}
    END

Investigate Critical Repository Issues for Repositories in Project `${AZURE_DEVOPS_PROJECT}`
    [Documentation]    Perform comprehensive investigation of critical repository issues that might impact operations
    [Tags]    Repository    Critical    Investigation    Operations    access:read-only
    
    FOR    ${repo}    IN    @{REPOSITORY_LIST}
        Log    Investigating critical issues for repository: ${repo}
        ${critical_investigation}=    RW.CLI.Run Bash File
        ...    bash_file=critical-repository-investigation.sh
        ...    env=${env}
        ...    timeout_seconds=180
        ...    include_in_history=false
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=AZURE_DEVOPS_REPO="${repo}" ./critical-repository-investigation.sh
        
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat critical_repository_issues.json
        
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        EXCEPT
            Log    Failed to load critical repository issues JSON payload for repository ${repo}, defaulting to empty list.    WARN
            ${issue_list}=    Create List
        END
        
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=Repository should operate without critical issues in `${repo}`
                ...    actual=Critical repository issues detected in `${repo}`
                ...    title=${issue['title']} (Repository: ${repo})
                ...    reproduce_hint=${critical_investigation.cmd}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_steps']}
            END
        END
        
        RW.Core.Add Pre To Report    Critical Repository Investigation for ${repo}:
        RW.Core.Add Pre To Report    ${critical_investigation.stdout}
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
    ${AZURE_DEVOPS_PROJECT}=    RW.Core.Import User Variable    AZURE_DEVOPS_PROJECT
    ...    type=string
    ...    description=Azure DevOps project name.
    ...    pattern=\w*
    ${AZURE_DEVOPS_REPOS}=    RW.Core.Import User Variable    AZURE_DEVOPS_REPOS
    ...    type=string
    ...    description=Repository name(s) to analyze. Can be a single repository, comma-separated list, or 'All' for all repositories in the project.
    ...    pattern=.*
    ...    default=All
    
    ${REPO_SIZE_THRESHOLD_MB}=    RW.Core.Import User Variable    REPO_SIZE_THRESHOLD_MB
    ...    type=string
    ...    description=Repository size threshold in MB above which performance issues are flagged.
    ...    default=500
    ...    pattern=\w*
    ${STALE_BRANCH_DAYS}=    RW.Core.Import User Variable    STALE_BRANCH_DAYS
    ...    type=string
    ...    description=Number of days after which branches are considered stale.
    ...    default=90
    ...    pattern=\w*
    ${MIN_CODE_COVERAGE}=    RW.Core.Import User Variable    MIN_CODE_COVERAGE
    ...    type=string
    ...    description=Minimum code coverage percentage threshold.
    ...    default=80
    ...    pattern=\w*
    ${ANALYSIS_DAYS}=    RW.Core.Import User Variable    ANALYSIS_DAYS
    ...    type=string
    ...    description=Number of days to look back for recent changes and pipeline failures analysis.
    ...    default=7
    ...    pattern=\w*
    
    Log    Processing repository list...    INFO
    # Handle repository list - either "All" or explicit CSV list
    ${repos_all}=    Evaluate    "${AZURE_DEVOPS_REPOS}".strip().lower() == "all"
    
    IF    ${repos_all}
        Log    Auto-discovering all repositories in project ${AZURE_DEVOPS_PROJECT}...    INFO
        ${REPOSITORY_LIST}=    Discover All Repositories
    ELSE
        Log    Processing provided repository list: ${AZURE_DEVOPS_REPOS}    INFO
        # Convert comma-separated repositories to list and clean up
        ${REPOSITORY_LIST}=    Split String    ${AZURE_DEVOPS_REPOS}    ,
        ${cleaned_repos}=    Create List
        FOR    ${repo}    IN    @{REPOSITORY_LIST}
            ${repo_trimmed}=    Strip String    ${repo}
            IF    "${repo_trimmed}" != ""
                Append To List    ${cleaned_repos}    ${repo_trimmed}
            END
        END
        ${REPOSITORY_LIST}=    Set Variable    ${cleaned_repos}
        
        # Validate that we have at least one repository after cleanup
        ${repo_count}=    Get Length    ${REPOSITORY_LIST}
        IF    ${repo_count} == 0
            Fail    No valid repositories found in the provided list. Please provide either "All" or a comma-separated list of repository names.
        END
    END
    
    # Final validation
    ${repo_count}=    Get Length    ${REPOSITORY_LIST}
    IF    ${repo_count} == 0
        Fail    No repositories found or accessible. Check project name and permissions.
    END
    
    Log    Will monitor ${repo_count} repositories: ${REPOSITORY_LIST}    INFO
    
    Log    Setting suite variables...    INFO
    Set Suite Variable    ${AZURE_DEVOPS_ORG}    ${AZURE_DEVOPS_ORG}
    Set Suite Variable    ${AZURE_DEVOPS_PROJECT}    ${AZURE_DEVOPS_PROJECT}
    Set Suite Variable    ${REPOSITORY_LIST}    ${REPOSITORY_LIST}
    Set Suite Variable    ${REPO_SIZE_THRESHOLD_MB}    ${REPO_SIZE_THRESHOLD_MB}
    Set Suite Variable    ${STALE_BRANCH_DAYS}    ${STALE_BRANCH_DAYS}
    Set Suite Variable    ${MIN_CODE_COVERAGE}    ${MIN_CODE_COVERAGE}
    Set Suite Variable    ${ANALYSIS_DAYS}    ${ANALYSIS_DAYS}
    
    # Create the env dictionary for bash scripts
    ${env_dict}=    Create Dictionary
    ...    AZURE_DEVOPS_ORG=${AZURE_DEVOPS_ORG}
    ...    AZURE_DEVOPS_PROJECT=${AZURE_DEVOPS_PROJECT}
    ...    REPO_SIZE_THRESHOLD_MB=${REPO_SIZE_THRESHOLD_MB}
    ...    STALE_BRANCH_DAYS=${STALE_BRANCH_DAYS}
    ...    MIN_CODE_COVERAGE=${MIN_CODE_COVERAGE}
    ...    ANALYSIS_DAYS=${ANALYSIS_DAYS}
    ...    AUTH_TYPE=${AUTH_TYPE}
    Set Suite Variable    ${env}    ${env_dict}
    
    Log    Suite Initialization completed successfully!    INFO


Discover All Repositories
    [Documentation]    Auto-discover all repositories in the Azure DevOps project
    
    # Create a temporary env dictionary for this discovery call
    ${temp_env}=    Create Dictionary
    ...    AZURE_DEVOPS_ORG=${AZURE_DEVOPS_ORG}
    ...    AZURE_DEVOPS_PROJECT=${AZURE_DEVOPS_PROJECT}
    ...    AUTH_TYPE=${AUTH_TYPE}
    
    ${discover_repos}=    RW.CLI.Run Bash File
    ...    bash_file=discover-repositories.sh
    ...    env=${temp_env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    
    ${repos_result}=    RW.CLI.Run Cli
    ...    cmd=cat discovered_repositories.json
    
    TRY
        ${repos_data}=    Evaluate    json.loads(r'''${repos_result.stdout}''')    json
        ${repo_names}=    Evaluate    [repo['name'] for repo in ${repos_data}]
        RETURN    ${repo_names}
    EXCEPT
        Log    Failed to discover repositories, using fallback method...    WARN
        # Fallback: try to extract from stdout
        ${repo_lines}=    Split To Lines    ${discover_repos.stdout}
        ${repo_names}=    Create List
        FOR    ${line}    IN    @{repo_lines}
            ${line}=    Strip String    ${line}
            IF    "${line}" != "" and not "${line}".startswith("#") and not "${line}".startswith("Analyzing")
                Append To List    ${repo_names}    ${line}
            END
        END
        RETURN    ${repo_names}
    END 