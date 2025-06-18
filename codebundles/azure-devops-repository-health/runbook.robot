*** Settings ***
Documentation       Repository health monitoring for Azure DevOps focusing on code quality, security, and configuration issues that impact development workflows
Metadata            Author    runwhen
Metadata            Display Name    Azure DevOps Repository Health
Metadata            Supports    Azure    DevOps    Repository    CodeQuality    Security
Force Tags          Azure    DevOps    Repository    CodeQuality    Security

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check Repository Security Configuration for `${AZURE_DEVOPS_REPO}` in Project `${AZURE_DEVOPS_PROJECT}`
    [Documentation]    Check repository security settings, branch policies, and access controls for misconfigurations
    [Tags]    Repository    Security    Configuration    BranchPolicies    access:read-only
    
    ${security_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=repository-security-analysis.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat repository_security_analysis.json
    
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to load repository security JSON payload, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Repository security should be properly configured in project `${AZURE_DEVOPS_PROJECT}`
            ...    actual=Security configuration issues detected in repository `${AZURE_DEVOPS_REPO}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${security_analysis.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    
    RW.Core.Add Pre To Report    Repository Security Analysis:
    RW.Core.Add Pre To Report    ${security_analysis.stdout}

Analyze Code Quality for Repository `${AZURE_DEVOPS_REPO}` in Project `${AZURE_DEVOPS_PROJECT}`
    [Documentation]    Analyze repository for code quality issues, technical debt, and maintainability problems
    [Tags]    Repository    CodeQuality    TechnicalDebt    Maintainability    access:read-only
    
    ${quality_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=code-quality-analysis.sh
    ...    env=${env}
    ...    timeout_seconds=240
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat code_quality_analysis.json
    
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to load code quality JSON payload, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Code quality should meet standards in repository `${AZURE_DEVOPS_REPO}`
            ...    actual=Code quality issues detected in repository `${AZURE_DEVOPS_REPO}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${quality_analysis.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    
    RW.Core.Add Pre To Report    Code Quality Analysis:
    RW.Core.Add Pre To Report    ${quality_analysis.stdout}

Check Branch Management for Repository `${AZURE_DEVOPS_REPO}` in Project `${AZURE_DEVOPS_PROJECT}`
    [Documentation]    Analyze branch structure, stale branches, and merge patterns that indicate workflow issues
    [Tags]    Repository    BranchManagement    Workflow    GitFlow    access:read-only
    
    ${branch_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=branch-management-analysis.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat branch_management_analysis.json
    
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to load branch management JSON payload, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Branch management should follow best practices in repository `${AZURE_DEVOPS_REPO}`
            ...    actual=Branch management issues detected in repository `${AZURE_DEVOPS_REPO}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${branch_analysis.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    
    RW.Core.Add Pre To Report    Branch Management Analysis:
    RW.Core.Add Pre To Report    ${branch_analysis.stdout}

Analyze Pull Request and Collaboration Patterns for Repository `${AZURE_DEVOPS_REPO}` in Project `${AZURE_DEVOPS_PROJECT}`
    [Documentation]    Examine PR review patterns, contributor activity, and collaboration health indicators
    [Tags]    Repository    PullRequests    Collaboration    CodeReview    access:read-only
    
    ${collaboration_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=collaboration-analysis.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat collaboration_analysis.json
    
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to load collaboration JSON payload, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Collaboration patterns should be healthy in repository `${AZURE_DEVOPS_REPO}`
            ...    actual=Collaboration issues detected in repository `${AZURE_DEVOPS_REPO}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${collaboration_analysis.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    
    RW.Core.Add Pre To Report    Collaboration Analysis:
    RW.Core.Add Pre To Report    ${collaboration_analysis.stdout}

Check Repository Performance and Size for Repository `${AZURE_DEVOPS_REPO}` in Project `${AZURE_DEVOPS_PROJECT}`
    [Documentation]    Analyze repository performance metrics and identify size-related issues
    [Tags]    Repository    Performance    Size    Storage    access:read-only
    
    ${performance_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=repository-performance-analysis.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat repository_performance_analysis.json
    
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to load repository performance JSON payload, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Repository performance should be optimal in repository `${AZURE_DEVOPS_REPO}`
            ...    actual=Performance issues detected in repository `${AZURE_DEVOPS_REPO}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${performance_analysis.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    
    RW.Core.Add Pre To Report    Repository Performance Analysis:
    RW.Core.Add Pre To Report    ${performance_analysis.stdout}

Investigate Critical Security Issues for Repository `${AZURE_DEVOPS_REPO}` in Project `${AZURE_DEVOPS_PROJECT}`
    [Documentation]    Deep dive investigation for critical security misconfigurations or incidents
    [Tags]    Repository    Security    Investigation    Critical    access:read-only
    
    ${security_investigation}=    RW.CLI.Run Bash File
    ...    bash_file=security-incident-check.sh
    ...    env=${env}
    ...    timeout_seconds=240
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat security_incident_analysis.json
    
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to load security investigation JSON payload, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Repository should have no critical security issues in `${AZURE_DEVOPS_REPO}`
            ...    actual=Critical security issues detected in repository `${AZURE_DEVOPS_REPO}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${security_investigation.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    
    RW.Core.Add Pre To Report    Security Investigation:
    RW.Core.Add Pre To Report    ${security_investigation.stdout}

Analyze Critical Repository Issues for Repository `${AZURE_DEVOPS_REPO}` in Project `${AZURE_DEVOPS_PROJECT}`
    [Documentation]    Investigate critical repository health issues that require immediate attention
    [Tags]    Repository    Investigation    Critical    Issues    access:read-only
    
    ${critical_investigation}=    RW.CLI.Run Bash File
    ...    bash_file=critical-repository-investigation.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat critical_repository_issues.json
    
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to load critical repository issues JSON payload, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Repository should operate without critical issues in `${AZURE_DEVOPS_REPO}`
            ...    actual=Critical repository issues detected in `${AZURE_DEVOPS_REPO}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${critical_investigation.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    
    RW.Core.Add Pre To Report    Critical Repository Investigation:
    RW.Core.Add Pre To Report    ${critical_investigation.stdout}


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
    ${AZURE_DEVOPS_PROJECT}=    RW.Core.Import User Variable    AZURE_DEVOPS_PROJECT
    ...    type=string
    ...    description=Azure DevOps project name.
    ...    pattern=\w*
    ${AZURE_DEVOPS_REPO}=    RW.Core.Import User Variable    AZURE_DEVOPS_REPO
    ...    type=string
    ...    description=Repository name to analyze.
    ...    pattern=\w*
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
    
    Set Suite Variable    ${AZURE_DEVOPS_ORG}    ${AZURE_DEVOPS_ORG}
    Set Suite Variable    ${AZURE_DEVOPS_PROJECT}    ${AZURE_DEVOPS_PROJECT}
    Set Suite Variable    ${AZURE_DEVOPS_REPO}    ${AZURE_DEVOPS_REPO}
    Set Suite Variable    ${REPO_SIZE_THRESHOLD_MB}    ${REPO_SIZE_THRESHOLD_MB}
    Set Suite Variable    ${STALE_BRANCH_DAYS}    ${STALE_BRANCH_DAYS}
    Set Suite Variable    ${MIN_CODE_COVERAGE}    ${MIN_CODE_COVERAGE}
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_DEVOPS_ORG":"${AZURE_DEVOPS_ORG}", "AZURE_DEVOPS_PROJECT":"${AZURE_DEVOPS_PROJECT}", "AZURE_DEVOPS_REPO":"${AZURE_DEVOPS_REPO}", "REPO_SIZE_THRESHOLD_MB":"${REPO_SIZE_THRESHOLD_MB}", "STALE_BRANCH_DAYS":"${STALE_BRANCH_DAYS}", "MIN_CODE_COVERAGE":"${MIN_CODE_COVERAGE}", "AUTH_TYPE":"${AUTH_TYPE}"} 