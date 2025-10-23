*** Settings ***
Documentation       Comprehensive health monitoring for Git repositories across specified repositories and organizations
Metadata            Author    stewartshea
Metadata            Display Name    Git Repository Health Monitoring
Metadata            Supports    GitHub,Git

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.NextSteps
Library             OperatingSystem
Library             String

Suite Setup         Suite Initialization


*** Tasks ***
Analyze Recent Commits Across Specified Repositories
    [Documentation]    Analyzes recent commit activity across the specified repositories and identifies patterns in development activity
    [Tags]
    ...    github
    ...    git
    ...    commits
    ...    repositories
    ...    multi-repo
    ...    multi-org
    ...    access:read-only
    ${recent_commits}=    RW.CLI.Run Bash File
    ...    bash_file=check_recent_commits.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    include_in_history=false
    ...    timeout_seconds=300
    ...    show_in_rwl_cheatsheet=true
    TRY
        ${commits_data}=    Evaluate    json.loads(r'''${recent_commits.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${commits_data}=    Create List
    END
    IF    len(@{commits_data}) > 0
        FOR    ${repo_data}    IN    @{commits_data}
            ${repo_name}=    Set Variable    ${repo_data.get('repository', 'unknown')}
            ${total_commits}=    Set Variable    ${repo_data.get('total_commits', 0)}
            ${contributors}=    Set Variable    ${repo_data.get('unique_contributors', 0)}
            ${health_score}=    Set Variable    ${repo_data.get('repository_health_score', 0)}
            ${is_stale}=    Set Variable    ${repo_data.get('is_stale', False)}
            ${days_since_last}=    Set Variable    ${repo_data.get('days_since_last_commit', 999)}
            
            IF    ${is_stale}
                RW.Core.Add Issue
                ...    severity=2
                ...    expected=Repository should have recent commit activity
                ...    actual=Repository ${repo_name} has been inactive for ${days_since_last} days
                ...    title=Stale Repository Detected: ${repo_name}
                ...    reproduce_hint=Check repository activity and maintenance status for ${repo_name}
                ...    details=Repository ${repo_name} shows signs of being stale:\n- Days since last commit: ${days_since_last}\n- Total commits in period: ${total_commits}\n- Unique contributors: ${contributors}\n- Health score: ${health_score}
                ...    next_steps=Consider archiving inactive repositories or implementing maintenance schedules
            ELSE IF    ${health_score} < 0.5
                RW.Core.Add Issue
                ...    severity=3
                ...    expected=Repository should maintain healthy development activity
                ...    actual=Repository ${repo_name} has low health score of ${health_score}
                ...    title=Low Repository Health: ${repo_name}
                ...    reproduce_hint=Review commit patterns and contributor activity for ${repo_name}
                ...    details=Repository ${repo_name} has concerning health metrics:\n- Health score: ${health_score}\n- Total commits: ${total_commits}\n- Contributors: ${contributors}\n- Days since last commit: ${days_since_last}
                ...    next_steps=Investigate development patterns and consider increasing development activity
            END
            
            # Display recent commits for active repositories
            IF    not ${is_stale} and ${total_commits} > 0
                ${recent_commits_list}=    Set Variable    ${repo_data.get('recent_commits', [])}
                IF    len(@{recent_commits_list}) > 0
                    Log    Recent commits for ${repo_name}:    INFO
                    FOR    ${commit}    IN    @{recent_commits_list}
                        ${commit_sha}=    Set Variable    ${commit.get('sha', '')}
                        ${commit_message}=    Set Variable    ${commit.get('message', '')}
                        ${commit_author}=    Set Variable    ${commit.get('author', '')}
                        ${commit_date}=    Set Variable    ${commit.get('date', '')}
                        Log    - ${commit_sha}: ${commit_message} (by ${commit_author} on ${commit_date})    INFO
                    END
                END
            END
        END
    ELSE
        RW.Core.Add Issue
        ...    severity=1
        ...    expected=Should be able to analyze repository commit data
        ...    actual=No repository data available for analysis
        ...    title=No Repository Data Available
        ...    reproduce_hint=Check GitHub token permissions and repository access
        ...    details=Unable to retrieve commit data for any repositories. This may indicate authentication issues or lack of repository access.
        ...    next_steps=Verify GitHub token has appropriate repository read permissions
    END

Check Repository Health Summary Across Specified Repositories
    [Documentation]    Provides an overall health assessment across all specified repositories
    [Tags]
    ...    github
    ...    git
    ...    health
    ...    summary
    ...    repositories
    ...    multi-repo
    ...    multi-org
    ...    access:read-only
    ${health_summary}=    RW.CLI.Run Bash File
    ...    bash_file=check_repo_health_summary.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    include_in_history=false
    ...    timeout_seconds=300
    ...    show_in_rwl_cheatsheet=true
    TRY
        ${summary_data}=    Evaluate    json.loads(r'''${health_summary.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty summary.    WARN
        ${summary_data}=    Create Dictionary    summary={}    metrics={}    repository_details=[]
    END
    
    ${summary}=    Set Variable    ${summary_data.get('summary', {})}
    ${metrics}=    Set Variable    ${summary_data.get('metrics', {})}
    ${repo_details}=    Set Variable    ${summary_data.get('repository_details', [])}
    
    ${total_repos}=    Set Variable    ${summary.get('total_repositories', 0)}
    ${healthy_count}=    Set Variable    ${summary.get('healthy_count', 0)}
    ${stale_count}=    Set Variable    ${summary.get('stale_count', 0)}
    ${overall_health_score}=    Set Variable    ${summary.get('overall_health_score', 1.0)}
    ${stale_percentage}=    Set Variable    ${summary.get('stale_percentage', 0)}
    ${health_threshold_met}=    Set Variable    ${summary.get('health_threshold_met', True)}
    
    Log    Repository Health Summary:    INFO
    Log    - Total repositories analyzed: ${total_repos}    INFO
    Log    - Healthy repositories: ${healthy_count}    INFO
    Log    - Stale repositories: ${stale_count}    INFO
    Log    - Overall health score: ${overall_health_score}    INFO
    Log    - Stale percentage: ${stale_percentage}%    INFO
    
    IF    not ${health_threshold_met}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Repository portfolio should maintain healthy development activity
        ...    actual=Overall repository health does not meet thresholds (score: ${overall_health_score}, stale: ${stale_percentage}%)
        ...    title=Repository Portfolio Health Below Threshold
        ...    reproduce_hint=Review individual repository health metrics and stale repository list
        ...    details=Repository portfolio health assessment:\n- Total repositories: ${total_repos}\n- Healthy repositories: ${healthy_count}\n- Stale repositories: ${stale_count}\n- Overall health score: ${overall_health_score}\n- Stale percentage: ${stale_percentage}%
        ...    next_steps=Review stale repositories for archival or increased maintenance activity
    END
    
    IF    ${stale_count} > 0
        ${stale_repos}=    Set Variable    ${summary.get('stale_repositories', [])}
        Log    Stale repositories detected:    WARN
        FOR    ${stale_repo}    IN    @{stale_repos}
            Log    - ${stale_repo}    WARN
        END
        
        RW.NextSteps.Add NextStep
        ...    Review stale repositories for potential archival or maintenance
        ...    Consider implementing automated maintenance schedules for inactive repositories
        ...    Evaluate whether stale repositories should be archived or require development attention
    END

Identify Stale Repositories Across Specified Repositories
    [Documentation]    Identifies repositories that have been inactive for extended periods and provides detailed staleness analysis
    [Tags]
    ...    github
    ...    git
    ...    stale
    ...    maintenance
    ...    repositories
    ...    multi-repo
    ...    multi-org
    ...    access:read-only
    ${stale_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=identify_stale_repositories.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    include_in_history=false
    ...    timeout_seconds=300
    ...    show_in_rwl_cheatsheet=true
    TRY
        ${stale_data}=    Evaluate    json.loads(r'''${stale_analysis.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty analysis.    WARN
        ${stale_data}=    Create Dictionary    summary={}    repositories=[]
    END
    
    ${summary}=    Set Variable    ${stale_data.get('summary', {})}
    ${repositories}=    Set Variable    ${stale_data.get('repositories', [])}
    
    ${total_repos}=    Set Variable    ${summary.get('total_repositories', 0)}
    ${stale_repos}=    Set Variable    ${summary.get('stale_repositories', 0)}
    ${stale_percentage}=    Set Variable    ${summary.get('stale_percentage', 0)}
    
    Log    Stale Repository Analysis:    INFO
    Log    - Total repositories: ${total_repos}    INFO
    Log    - Stale repositories: ${stale_repos}    INFO
    Log    - Stale percentage: ${stale_percentage}%    INFO
    
    IF    ${stale_repos} > 0
        Log    Detailed stale repository analysis:    WARN
        FOR    ${repo}    IN    @{repositories}
            ${is_stale}=    Set Variable    ${repo.get('is_stale', False)}
            IF    ${is_stale}
                ${repo_name}=    Set Variable    ${repo.get('repository', 'unknown')}
                ${staleness_level}=    Set Variable    ${repo.get('staleness_level', 'unknown')}
                ${days_since_last}=    Set Variable    ${repo.get('days_since_last_commit', 0)}
                ${maintenance_status}=    Set Variable    ${repo.get('maintenance_status', 'unknown')}
                ${repo_info}=    Set Variable    ${repo.get('repository_info', {})}
                ${last_commit}=    Set Variable    ${repo.get('last_commit', {})}
                
                ${is_archived}=    Set Variable    ${repo_info.get('is_archived', False)}
                ${stars}=    Set Variable    ${repo_info.get('stars', 0)}
                ${forks}=    Set Variable    ${repo_info.get('forks', 0)}
                ${language}=    Set Variable    ${repo_info.get('language', 'Unknown')}
                
                Log    Stale Repository: ${repo_name}    WARN
                Log    - Staleness level: ${staleness_level}    WARN
                Log    - Days since last commit: ${days_since_last}    WARN
                Log    - Maintenance status: ${maintenance_status}    WARN
                Log    - Language: ${language}    WARN
                Log    - Stars: ${stars}, Forks: ${forks}    WARN
                Log    - Archived: ${is_archived}    WARN
                
                IF    '${staleness_level}' == 'very_stale'
                    RW.Core.Add Issue
                    ...    severity=1
                    ...    expected=Repository should have regular maintenance or be archived
                    ...    actual=Repository ${repo_name} has been inactive for ${days_since_last} days (very stale)
                    ...    title=Very Stale Repository: ${repo_name}
                    ...    reproduce_hint=Check repository for archival consideration
                    ...    details=Repository ${repo_name} is very stale:\n- Days inactive: ${days_since_last}\n- Maintenance status: ${maintenance_status}\n- Language: ${language}\n- Stars: ${stars}, Forks: ${forks}\n- Archived: ${is_archived}
                    ...    next_steps=Consider archiving this repository if it's no longer maintained
                ELSE IF    '${staleness_level}' == 'stale'
                    RW.Core.Add Issue
                    ...    severity=2
                    ...    expected=Repository should have recent development activity
                    ...    actual=Repository ${repo_name} has been inactive for ${days_since_last} days
                    ...    title=Stale Repository: ${repo_name}
                    ...    reproduce_hint=Review repository maintenance needs
                    ...    details=Repository ${repo_name} shows staleness:\n- Days inactive: ${days_since_last}\n- Maintenance status: ${maintenance_status}\n- Language: ${language}\n- Stars: ${stars}, Forks: ${forks}
                    ...    next_steps=Evaluate if repository needs maintenance or should be archived
                END
            END
        END
        
        RW.NextSteps.Add NextStep
        ...    Review stale repositories for archival decisions
        ...    Implement repository maintenance schedules for active projects
        ...    Consider automated notifications for repositories approaching staleness thresholds
    END

Generate Repository Health Recommendations
    [Documentation]    Generates actionable recommendations based on repository health analysis
    [Tags]
    ...    github
    ...    git
    ...    recommendations
    ...    health
    ...    repositories
    ...    multi-repo
    ...    multi-org
    ...    access:read-only
    
    # This task aggregates findings and provides strategic recommendations
    Log    Generating repository health recommendations...    INFO
    
    RW.NextSteps.Add NextStep
    ...    Implement automated repository health monitoring
    ...    Set up regular health checks and alerts for repository portfolios
    ...    Consider implementing repository lifecycle management policies
    
    RW.NextSteps.Add NextStep
    ...    Establish repository maintenance guidelines
    ...    Create guidelines for minimum commit frequency and contributor activity
    ...    Define clear criteria for repository archival decisions
    
    RW.NextSteps.Add NextStep
    ...    Monitor commit quality and patterns
    ...    Implement commit message standards and quality checks
    ...    Track contributor diversity and engagement metrics


*** Keywords ***
Suite Initialization
    ${GITHUB_TOKEN}=    RW.Core.Import Secret    GITHUB_TOKEN
    ...    type=string
    ...    description=GitHub Personal Access Token with repository read permissions
    ...    pattern=\w*
    ...    example=ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
    ${GITHUB_REPOS}=    RW.Core.Import User Variable    GITHUB_REPOS
    ...    type=string
    ...    description=Comma-separated list of GitHub repositories in format owner/repo, or 'ALL' for all org repositories
    ...    pattern=\w*
    ...    example=microsoft/vscode,microsoft/typescript
    ...    default=ALL
    ${GITHUB_ORGS}=    RW.Core.Import User Variable    GITHUB_ORGS
    ...    type=string
    ...    description=GitHub organization names (single org or comma-separated list for multiple orgs)
    ...    pattern=\w*
    ...    example=microsoft,github
    ...    default=""
    ${COMMIT_LOOKBACK_DAYS}=    RW.Core.Import User Variable    COMMIT_LOOKBACK_DAYS
    ...    type=string
    ...    description=Number of days to look back for commit analysis
    ...    pattern=^\d+$
    ...    example=30
    ...    default=30
    ${STALE_REPO_THRESHOLD_DAYS}=    RW.Core.Import User Variable    STALE_REPO_THRESHOLD_DAYS
    ...    type=string
    ...    description=Number of days without commits to consider a repository stale
    ...    pattern=^\d+$
    ...    example=90
    ...    default=90
    ${MIN_COMMITS_HEALTHY}=    RW.Core.Import User Variable    MIN_COMMITS_HEALTHY
    ...    type=string
    ...    description=Minimum number of commits in the lookback period for a healthy repository
    ...    pattern=^\d+$
    ...    example=5
    ...    default=5
    ${MAX_REPOS_TO_ANALYZE}=    RW.Core.Import User Variable    MAX_REPOS_TO_ANALYZE
    ...    type=string
    ...    description=Maximum number of repositories to analyze
    ...    pattern=^\d+$
    ...    example=50
    ...    default=50
    ${MAX_REPOS_PER_ORG}=    RW.Core.Import User Variable    MAX_REPOS_PER_ORG
    ...    type=string
    ...    description=Maximum number of repositories per organization
    ...    pattern=^\d+$
    ...    example=20
    ...    default=20
    ${MIN_REPO_HEALTH_SCORE}=    RW.Core.Import User Variable    MIN_REPO_HEALTH_SCORE
    ...    type=string
    ...    description=Minimum acceptable repository health score (0.0-1.0)
    ...    pattern=^\d*\.?\d+$
    ...    example=0.7
    ...    default=0.7
    ${MAX_STALE_REPOS_PERCENTAGE}=    RW.Core.Import User Variable    MAX_STALE_REPOS_PERCENTAGE
    ...    type=string
    ...    description=Maximum percentage of stale repositories considered healthy
    ...    pattern=^\d+$
    ...    example=20
    ...    default=20
    Set Suite Variable    ${GITHUB_TOKEN}    ${GITHUB_TOKEN}
    Set Suite Variable    ${GITHUB_REPOS}    ${GITHUB_REPOS}
    Set Suite Variable    ${GITHUB_ORGS}    ${GITHUB_ORGS}
    Set Suite Variable    ${COMMIT_LOOKBACK_DAYS}    ${COMMIT_LOOKBACK_DAYS}
    Set Suite Variable    ${STALE_REPO_THRESHOLD_DAYS}    ${STALE_REPO_THRESHOLD_DAYS}
    Set Suite Variable    ${MIN_COMMITS_HEALTHY}    ${MIN_COMMITS_HEALTHY}
    Set Suite Variable    ${MAX_REPOS_TO_ANALYZE}    ${MAX_REPOS_TO_ANALYZE}
    Set Suite Variable    ${MAX_REPOS_PER_ORG}    ${MAX_REPOS_PER_ORG}
    Set Suite Variable    ${MIN_REPO_HEALTH_SCORE}    ${MIN_REPO_HEALTH_SCORE}
    Set Suite Variable    ${MAX_STALE_REPOS_PERCENTAGE}    ${MAX_STALE_REPOS_PERCENTAGE}
    Set Suite Variable
    ...    ${env}
    ...    {"GITHUB_REPOS":"${GITHUB_REPOS}", "GITHUB_ORGS":"${GITHUB_ORGS}", "COMMIT_LOOKBACK_DAYS":"${COMMIT_LOOKBACK_DAYS}", "STALE_REPO_THRESHOLD_DAYS":"${STALE_REPO_THRESHOLD_DAYS}", "MIN_COMMITS_HEALTHY":"${MIN_COMMITS_HEALTHY}", "MAX_REPOS_TO_ANALYZE":"${MAX_REPOS_TO_ANALYZE}", "MAX_REPOS_PER_ORG":"${MAX_REPOS_PER_ORG}", "MIN_REPO_HEALTH_SCORE":"${MIN_REPO_HEALTH_SCORE}", "MAX_STALE_REPOS_PERCENTAGE":"${MAX_STALE_REPOS_PERCENTAGE}"}
