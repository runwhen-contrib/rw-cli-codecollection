*** Settings ***
Documentation       Service Level Indicators for Git Repository Health Monitoring
Metadata            Author    stewartshea
Metadata            Display Name    Git Repository Health SLI
Metadata            Supports    GitHub,Git

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Calculate Repository Health Score Across Specified Repositories
    [Documentation]    Calculates the overall health score of repositories across the specified repositories over the specified period
    [Tags]    github    git    repository    health-score    sli    multi-repo
    ${repo_health_sli}=    RW.CLI.Run Bash File
    ...    bash_file=calculate_repo_health_sli.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    include_in_history=false
    ...    timeout_seconds=180
    TRY
        ${sli_data}=    Evaluate    json.loads(r'''${repo_health_sli.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to perfect score.    WARN
        ${sli_data}=    Create Dictionary    sli_score=1.0    metrics={}
    END
    ${sli_score}=    Set Variable    ${sli_data.get('sli_score', 1.0)}
    ${metrics}=    Set Variable    ${sli_data.get('metrics', {})}
    ${avg_health_score}=    Set Variable    ${metrics.get('avg_health_score', 1.0)}
    ${healthy_percentage}=    Set Variable    ${metrics.get('healthy_percentage', 1.0)}
    
    ${repo_health_score}=    Evaluate    1 if float(${sli_score}) >= 1 else 0
    Set Global Variable    ${repo_health_score}
    RW.Core.Push Metric    ${repo_health_score}    sub_name=repo_health

Calculate Commit Frequency Score Across Specified Repositories
    [Documentation]    Calculates the commit frequency health score across the specified repositories
    [Tags]    github    git    commits    frequency    sli    multi-repo
    ${commit_frequency_sli}=    RW.CLI.Run Bash File
    ...    bash_file=calculate_commit_frequency_sli.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    include_in_history=false
    ...    timeout_seconds=180
    TRY
        ${frequency_data}=    Evaluate    json.loads(r'''${commit_frequency_sli.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to perfect score.    WARN
        ${frequency_data}=    Create Dictionary    sli_score=1.0    metrics={}
    END
    ${frequency_sli_score}=    Set Variable    ${frequency_data.get('sli_score', 1.0)}
    ${metrics}=    Set Variable    ${frequency_data.get('metrics', {})}
    ${avg_frequency_score}=    Set Variable    ${metrics.get('avg_frequency_score', 1.0)}
    ${repos_meeting_threshold}=    Set Variable    ${metrics.get('repos_meeting_threshold', 0)}
    
    ${commit_frequency_score}=    Evaluate    1 if float(${frequency_sli_score}) >= 1 else 0
    Set Global Variable    ${commit_frequency_score}
    RW.Core.Push Metric    ${commit_frequency_score}    sub_name=commit_frequency

Calculate Repository Freshness Score Across Specified Repositories
    [Documentation]    Calculates repository freshness based on recent activity across the specified repositories
    [Tags]    github    git    freshness    activity    sli    multi-repo
    
    # Use the repo health SLI data to calculate freshness component
    ${repo_health_sli}=    RW.CLI.Run Bash File
    ...    bash_file=calculate_repo_health_sli.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    include_in_history=false
    ...    timeout_seconds=180
    TRY
        ${sli_data}=    Evaluate    json.loads(r'''${repo_health_sli.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to perfect score.    WARN
        ${sli_data}=    Create Dictionary    individual_scores=[]    repositories=[]
    END
    
    ${individual_scores}=    Set Variable    ${sli_data.get('individual_scores', [])}
    ${repositories}=    Set Variable    ${sli_data.get('repositories', [])}
    
    # Calculate freshness score based on individual repository scores
    # Freshness is considered good if most repositories have recent activity
    ${total_repos}=    Get Length    ${repositories}
    ${fresh_repos}=    Set Variable    0
    
    IF    ${total_repos} > 0
        FOR    ${score}    IN    @{individual_scores}
            # Consider a repository "fresh" if its health score is above 0.6
            ${is_fresh}=    Evaluate    float(${score}) >= 0.6
            IF    ${is_fresh}
                ${fresh_repos}=    Evaluate    ${fresh_repos} + 1
            END
        END
        ${freshness_percentage}=    Evaluate    ${fresh_repos} / ${total_repos}
    ELSE
        ${freshness_percentage}=    Set Variable    1.0
    END
    
    # SLI passes if at least 70% of repositories are considered fresh
    ${min_freshness_threshold}=    Set Variable    ${MIN_REPO_FRESHNESS_SCORE}
    ${freshness_score}=    Evaluate    1 if float(${freshness_percentage}) >= float(${min_freshness_threshold}) else 0
    Set Global Variable    ${freshness_score}
    RW.Core.Push Metric    ${freshness_score}    sub_name=repo_freshness

Calculate Contributor Diversity Score Across Specified Repositories
    [Documentation]    Calculates contributor diversity health score across the specified repositories
    [Tags]    github    git    contributors    diversity    sli    multi-repo
    
    # This would ideally be a separate script, but for now we'll derive it from the main health data
    ${repo_health_sli}=    RW.CLI.Run Bash File
    ...    bash_file=calculate_repo_health_sli.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    include_in_history=false
    ...    timeout_seconds=180
    TRY
        ${sli_data}=    Evaluate    json.loads(r'''${repo_health_sli.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to perfect score.    WARN
        ${sli_data}=    Create Dictionary    metrics={}
    END
    
    ${metrics}=    Set Variable    ${sli_data.get('metrics', {})}
    ${healthy_percentage}=    Set Variable    ${metrics.get('healthy_percentage', 1.0)}
    
    # Use healthy percentage as a proxy for contributor diversity health
    # This assumes that healthy repositories generally have good contributor diversity
    ${min_diversity_threshold}=    Set Variable    ${MIN_CONTRIBUTOR_DIVERSITY_SCORE}
    ${contributor_diversity_score}=    Evaluate    1 if float(${healthy_percentage}) >= float(${min_diversity_threshold}) else 0
    Set Global Variable    ${contributor_diversity_score}
    RW.Core.Push Metric    ${contributor_diversity_score}    sub_name=contributor_diversity

Generate Overall Git Repository Health Score
    [Documentation]    Generates a composite health score from all measured indicators
    [Tags]    github    git    health-score    sli    composite
    
    # Initialize scores to 1 if not set (meaning those checks weren't run)
    ${repo_health_score}=    Set Variable If    '${repo_health_score}' != '${EMPTY}'    ${repo_health_score}    1
    ${commit_frequency_score}=    Set Variable If    '${commit_frequency_score}' != '${EMPTY}'    ${commit_frequency_score}    1
    ${freshness_score}=    Set Variable If    '${freshness_score}' != '${EMPTY}'    ${freshness_score}    1
    ${contributor_diversity_score}=    Set Variable If    '${contributor_diversity_score}' != '${EMPTY}'    ${contributor_diversity_score}    1
    
    # Calculate weighted composite score
    # Repository Health: 40%, Commit Frequency: 30%, Freshness: 20%, Contributor Diversity: 10%
    ${composite_score}=    Evaluate    float(${repo_health_score}) * 0.40 + float(${commit_frequency_score}) * 0.30 + float(${freshness_score}) * 0.20 + float(${contributor_diversity_score}) * 0.10
    ${health_score}=    Convert to Number    ${composite_score}    2
    RW.Core.Push Metric    ${health_score}


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
    ${MIN_REPO_HEALTH_SCORE}=    RW.Core.Import User Variable    MIN_REPO_HEALTH_SCORE
    ...    type=string
    ...    description=Minimum acceptable repository health score (0.0-1.0)
    ...    pattern=^\d*\.?\d+$
    ...    example=0.7
    ...    default=0.7
    ${MIN_COMMIT_FREQUENCY_SCORE}=    RW.Core.Import User Variable    MIN_COMMIT_FREQUENCY_SCORE
    ...    type=string
    ...    description=Minimum acceptable commit frequency score (0.0-1.0)
    ...    pattern=^\d*\.?\d+$
    ...    example=0.6
    ...    default=0.6
    ${MIN_REPO_FRESHNESS_SCORE}=    RW.Core.Import User Variable    MIN_REPO_FRESHNESS_SCORE
    ...    type=string
    ...    description=Minimum acceptable repository freshness score (0.0-1.0)
    ...    pattern=^\d*\.?\d+$
    ...    example=0.7
    ...    default=0.7
    ${MIN_CONTRIBUTOR_DIVERSITY_SCORE}=    RW.Core.Import User Variable    MIN_CONTRIBUTOR_DIVERSITY_SCORE
    ...    type=string
    ...    description=Minimum acceptable contributor diversity score (0.0-1.0)
    ...    pattern=^\d*\.?\d+$
    ...    example=0.5
    ...    default=0.5
    ${MIN_COMMITS_HEALTHY}=    RW.Core.Import User Variable    MIN_COMMITS_HEALTHY
    ...    type=string
    ...    description=Minimum number of commits in the lookback period for a healthy repository
    ...    pattern=^\d+$
    ...    example=5
    ...    default=5
    ${SLI_LOOKBACK_DAYS}=    RW.Core.Import User Variable    SLI_LOOKBACK_DAYS
    ...    type=string
    ...    description=Number of days to look back for SLI calculations
    ...    pattern=^\d*\.?\d+$
    ...    example=1
    ...    default=1
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
    Set Suite Variable    ${GITHUB_TOKEN}    ${GITHUB_TOKEN}
    Set Suite Variable    ${GITHUB_REPOS}    ${GITHUB_REPOS}
    Set Suite Variable    ${GITHUB_ORGS}    ${GITHUB_ORGS}
    Set Suite Variable    ${MIN_REPO_HEALTH_SCORE}    ${MIN_REPO_HEALTH_SCORE}
    Set Suite Variable    ${MIN_COMMIT_FREQUENCY_SCORE}    ${MIN_COMMIT_FREQUENCY_SCORE}
    Set Suite Variable    ${MIN_REPO_FRESHNESS_SCORE}    ${MIN_REPO_FRESHNESS_SCORE}
    Set Suite Variable    ${MIN_CONTRIBUTOR_DIVERSITY_SCORE}    ${MIN_CONTRIBUTOR_DIVERSITY_SCORE}
    Set Suite Variable    ${MIN_COMMITS_HEALTHY}    ${MIN_COMMITS_HEALTHY}
    Set Suite Variable    ${SLI_LOOKBACK_DAYS}    ${SLI_LOOKBACK_DAYS}
    Set Suite Variable    ${MAX_REPOS_TO_ANALYZE}    ${MAX_REPOS_TO_ANALYZE}
    Set Suite Variable    ${MAX_REPOS_PER_ORG}    ${MAX_REPOS_PER_ORG}
    Set Suite Variable
    ...    ${env}
    ...    {"GITHUB_REPOS":"${GITHUB_REPOS}", "GITHUB_ORGS":"${GITHUB_ORGS}", "MIN_REPO_HEALTH_SCORE":"${MIN_REPO_HEALTH_SCORE}", "MIN_COMMIT_FREQUENCY_SCORE":"${MIN_COMMIT_FREQUENCY_SCORE}", "MIN_REPO_FRESHNESS_SCORE":"${MIN_REPO_FRESHNESS_SCORE}", "MIN_CONTRIBUTOR_DIVERSITY_SCORE":"${MIN_CONTRIBUTOR_DIVERSITY_SCORE}", "MIN_COMMITS_HEALTHY":"${MIN_COMMITS_HEALTHY}", "SLI_LOOKBACK_DAYS":"${SLI_LOOKBACK_DAYS}", "MAX_REPOS_TO_ANALYZE":"${MAX_REPOS_TO_ANALYZE}", "MAX_REPOS_PER_ORG":"${MAX_REPOS_PER_ORG}"}
