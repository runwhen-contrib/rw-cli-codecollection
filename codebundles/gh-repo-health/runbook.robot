*** Settings ***
Documentation       Comprehensive repository health monitoring across GitHub organizations — dormant repos, stale issues/PRs, branch hygiene, config health, release cadence, and contributor pulse.
Metadata            Author    stewartshea
Metadata            Display Name    GitHub Repository Health
Metadata            Supports    GitHub

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.NextSteps
Library             OperatingSystem
Library             String

Suite Setup         Suite Initialization


*** Tasks ***
Detect Dormant Repositories
    [Documentation]    Finds repositories with no commits or pushes in the last N days, flagging potentially abandoned projects.
    [Tags]    github    repositories    dormant    multi-repo    multi-org    access:read-only    data:config
    ${dormant_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_dormant_repos.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    secret__GITHUB_APP_ID=${GITHUB_APP_ID}
    ...    secret__GITHUB_APP_INSTALLATION_ID=${GITHUB_APP_INSTALLATION_ID}
    ...    secret__GITHUB_APP_CLIENT_ID=${GITHUB_APP_CLIENT_ID}
    ...    secret__GITHUB_APP_PRIVATE_KEY=${GITHUB_APP_PRIVATE_KEY}
    ...    include_in_history=false
    ...    timeout_seconds=300
    ...    show_in_rwl_cheatsheet=true
    TRY
        ${dormant_data}=    Evaluate    json.loads(r'''${dormant_result.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty.    WARN
        ${dormant_data}=    Create Dictionary    dormant_repositories=[]
    END
    ${dormant_repos}=    Set Variable    ${dormant_data.get('dormant_repositories', [])}
    ${dormant_count}=    Set Variable    ${dormant_data.get('dormant_repositories_count', 0)}
    IF    ${dormant_count} > 0
        ${dormant_summary}=    Set Variable    
        FOR    ${repo}    IN    @{dormant_repos}
            ${repo_name}=    Set Variable    ${repo['repository']}
            ${days}=    Set Variable    ${repo['days_since_last_activity']}
            ${committer}=    Set Variable    ${repo.get('last_committer', 'N/A')}
            ${archived}=    Set Variable    ${repo.get('archived', False)}
            ${archived_suffix}=    Set Variable If    ${archived} == True     (ARCHIVED)    ${EMPTY}
            ${dormant_summary}=    Set Variable    ${dormant_summary}\n${repo_name} — ${days} days (${committer})${archived_suffix}
        END
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=All repositories should have recent activity
        ...    actual=${dormant_count} dormant repositories found across ${dormant_data.get('repositories_analyzed', 0)} analyzed
        ...    title=${dormant_count} Dormant Repositories Detected
        ...    reproduce_hint=Review repository activity in the report
        ...    details=${dormant_summary}
        ...    next_steps=Review each repository for archival or cleanup\nReach out to last committers for context
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Dormant Repository Report:\n${dormant_result.stdout}

Detect Stale Issue Accumulation
    [Documentation]    Identifies repositories where open issues are stacking up — unassigned, unlabeled, or untouched for too long.
    [Tags]    github    issues    stale    backlog    multi-repo    multi-org    access:read-only    data:config
    ${stale_issues_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_stale_issues.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    secret__GITHUB_APP_ID=${GITHUB_APP_ID}
    ...    secret__GITHUB_APP_INSTALLATION_ID=${GITHUB_APP_INSTALLATION_ID}
    ...    secret__GITHUB_APP_CLIENT_ID=${GITHUB_APP_CLIENT_ID}
    ...    secret__GITHUB_APP_PRIVATE_KEY=${GITHUB_APP_PRIVATE_KEY}
    ...    include_in_history=false
    ...    timeout_seconds=300
    ...    show_in_rwl_cheatsheet=true
    TRY
        ${issues_data}=    Evaluate    json.loads(r'''${stale_issues_result.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty.    WARN
        ${issues_data}=    Create Dictionary
    END
    ${backlog_repos}=    Set Variable    ${issues_data.get('repos_with_high_backlog', [])}
    ${unresponded}=    Set Variable    ${issues_data.get('unresponded_issues_detail', [])}
    ${total_stale}=    Set Variable    ${issues_data.get('stale_issues', 0)}
    ${total_unassigned}=    Set Variable    ${issues_data.get('unassigned_issues', 0)}
    IF    ${total_stale} > ${STALE_ISSUE_THRESHOLD}
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Stale issues should be below ${STALE_ISSUE_THRESHOLD}
        ...    actual=Found ${total_stale} stale issues across analyzed repositories
        ...    title=${total_stale} Stale Issues Detected Across Repositories
        ...    reproduce_hint=Review issue backlogs in the report
        ...    details=Stale issues: ${total_stale}\nUnassigned: ${total_unassigned}\nUnlabeled: ${issues_data.get('unlabeled_issues', 0)}\nUnresponded: ${issues_data.get('unresponded_issues', 0)}
        ...    next_steps=Triage stale issues: close, assign, or update\nAdd labels to unlabeled issues\nSchedule backlog grooming sessions
    END
    IF    len(@{unresponded}) > 0
        ${ur_summary}=    Set Variable    
        ${ur_count}=    Evaluate    len(${unresponded})
        ${ur_repo}=    Set Variable    ${EMPTY}
        FOR    ${item}    IN    @{unresponded}
            ${ur_summary}=    Set Variable    ${ur_summary}\n#${item['issue_number']} "${item['title']}" in ${item['repository']} — ${item['days_since_last_team_response']} days without team response (author: ${item['author']}")
        END
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Issues should receive team responses in a timely manner
        ...    actual=${ur_count} items have no team response issues have no team response
        ...    title=${ur_count} Unresponded Issues Across Repositories Unresponded Issues Across Repositories
        ...    reproduce_hint=Review issue comments in the report
        ...    details=${ur_summary}
        ...    next_steps=Assign team members to respond to each issue\nCheck if issues need triage labels\nConsider closing if no longer relevant
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Stale Issue Report:\n${stale_issues_result.stdout}

Detect Stale Pull Requests
    [Documentation]    Finds PRs that have been open too long, lack reviews, or have merge conflicts, including who is blocking whom.
    [Tags]    github    pull-requests    stale    review-bottleneck    multi-repo    multi-org    access:read-only    data:config
    ${stale_prs_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_stale_prs.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    secret__GITHUB_APP_ID=${GITHUB_APP_ID}
    ...    secret__GITHUB_APP_INSTALLATION_ID=${GITHUB_APP_INSTALLATION_ID}
    ...    secret__GITHUB_APP_CLIENT_ID=${GITHUB_APP_CLIENT_ID}
    ...    secret__GITHUB_APP_PRIVATE_KEY=${GITHUB_APP_PRIVATE_KEY}
    ...    include_in_history=false
    ...    timeout_seconds=300
    ...    show_in_rwl_cheatsheet=true
    TRY
        ${prs_data}=    Evaluate    json.loads(r'''${stale_prs_result.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty.    WARN
        ${prs_data}=    Create Dictionary
    END
    ${stale_prs}=    Set Variable    ${prs_data.get('stale_prs', [])}
    ${conflict_prs}=    Set Variable    ${prs_data.get('conflict_prs', [])}
    ${unreviewed_prs}=    Set Variable    ${prs_data.get('unreviewed_prs', [])}
    IF    len(@{stale_prs}) > 0
        ${pr_count}=    Evaluate    len(${stale_prs})
        ${pr_summary}=    Set Variable    
        FOR    ${pr}    IN    @{stale_prs}
            ${waiting_on}=    Set Variable    ${pr.get('waiting_on', [])}
            ${waiting_str}=    Evaluate    ", ".join(${waiting_on}) if ${waiting_on} else "no one"
            ${pr_summary}=    Set Variable    ${pr_summary}\n#${pr['pr_number']} "${pr['title']}" in ${pr['repository']} by ${pr['author']} — ${pr['days_open']} days open (waiting: ${waiting_str})
        END
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=PRs should be merged or closed in a timely manner
        ...    actual=${pr_count} stale PRs across repos stale PRs across repos
        ...    title=${pr_count} Stale Pull Requests Detected Stale Pull Requests Detected
        ...    reproduce_hint=Review PR details in the report
        ...    details=${pr_summary}
        ...    next_steps=Ping reviewers for outstanding reviews\nResolve merge conflicts\nConsider breaking large PRs into smaller ones
    END
    IF    len(@{conflict_prs}) > 0
        ${cf_count}=    Evaluate    len(${conflict_prs})
        ${cf_summary}=    Set Variable    
        FOR    ${pr}    IN    @{conflict_prs}
            ${cf_summary}=    Set Variable    ${cf_summary}\n#${pr['pr_number']} "${pr['title']}" in ${pr['repository']} by ${pr['author']} — ${pr['days_open']} days open with merge conflicts
        END
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=PRs should be free of merge conflicts
        ...    actual=${cf_count} PRs with merge conflicts PRs with merge conflicts
        ...    title=${cf_count} PRs With Merge Conflicts PRs With Merge Conflicts
        ...    reproduce_hint=Review PR details in the report
        ...    details=${cf_summary}
        ...    next_steps=Resolve merge conflicts with latest default branch\nCoordinate with PR authors
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Stale PR Report:\n${stale_prs_result.stdout}

Audit Branch Hygiene
    [Documentation]    Finds stale branches that haven't been touched in N days — excluding default and protected branches.
    [Tags]    github    branches    hygiene    multi-repo    multi-org    access:read-only    data:config
    ${branches_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_branch_hygiene.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    secret__GITHUB_APP_ID=${GITHUB_APP_ID}
    ...    secret__GITHUB_APP_INSTALLATION_ID=${GITHUB_APP_INSTALLATION_ID}
    ...    secret__GITHUB_APP_CLIENT_ID=${GITHUB_APP_CLIENT_ID}
    ...    secret__GITHUB_APP_PRIVATE_KEY=${GITHUB_APP_PRIVATE_KEY}
    ...    include_in_history=false
    ...    timeout_seconds=300
    ...    show_in_rwl_cheatsheet=true
    TRY
        ${branches_data}=    Evaluate    json.loads(r'''${branches_result.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty.    WARN
        ${branches_data}=    Create Dictionary
    END
    ${stale_branches}=    Set Variable    ${branches_data.get('stale_branches', [])}
    ${stale_count}=    Set Variable    ${branches_data.get('stale_branches_count', 0)}
    IF    len(@{stale_branches}) > 0
        ${br_count}=    Evaluate    len(${stale_branches})
        ${br_summary}=    Set Variable    
        FOR    ${branch}    IN    @{stale_branches}
            ${br_summary}=    Set Variable    ${br_summary}\n${branch['branch']} in ${branch['repository']} — ${branch['days_since_commit']} days inactive (${branch['last_committer']})
        END
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Branches should be cleaned up after merging or abandonment
        ...    actual=${br_count} stale branches across repos stale branches across repos
        ...    title=${br_count} Stale Branches Detected Stale Branches Detected
        ...    reproduce_hint=Review branches in the report
        ...    details=${br_summary}
        ...    next_steps=Delete merged/abandoned branches\nContact committers for context on active branches
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Branch Hygiene Report:\n${branches_result.stdout}

Audit Repository Configuration Health
    [Documentation]    Audits repos for essential files (README, LICENSE, CONTRIBUTING, CODEOWNERS), branch protection, and community health scores.
    [Tags]    github    configuration    community-health    best-practices    multi-repo    multi-org    access:read-only    data:config
    ${config_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_repo_config_health.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    secret__GITHUB_APP_ID=${GITHUB_APP_ID}
    ...    secret__GITHUB_APP_INSTALLATION_ID=${GITHUB_APP_INSTALLATION_ID}
    ...    secret__GITHUB_APP_CLIENT_ID=${GITHUB_APP_CLIENT_ID}
    ...    secret__GITHUB_APP_PRIVATE_KEY=${GITHUB_APP_PRIVATE_KEY}
    ...    include_in_history=false
    ...    timeout_seconds=300
    ...    show_in_rwl_cheatsheet=true
    TRY
        ${config_data}=    Evaluate    json.loads(r'''${config_result.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty.    WARN
        ${config_data}=    Create Dictionary
    END
    ${findings}=    Set Variable    ${config_data.get('findings', [])}
    ${overall_health}=    Set Variable    ${config_data.get('overall_health_score', 1.0)}
    IF    len(@{findings}) > 0
        ${cf_summary}=    Set Variable    
        ${cf_issue_count}=    Set Variable    0
        FOR    ${finding}    IN    @{findings}
            ${repo_health}=    Set Variable    ${finding.get('health_score', 1.0)}
            ${checks}=    Set Variable    ${finding.get('checks', {})}
            ${repo_name}=    Set Variable    ${finding['repository']}
            ${missing}=    Create List
            IF    ${checks.get('readme', True)} == False    Append To List    ${missing}    README
            IF    ${checks.get('license', True)} == False    Append To List    ${missing}    LICENSE
            IF    ${checks.get('description', True)} == False    Append To List    ${missing}    Description
            IF    ${checks.get('contributing', True)} == False    Append To List    ${missing}    CONTRIBUTING.md
            IF    ${checks.get('codeowners', True)} == False    Append To List    ${missing}    CODEOWNERS
            IF    ${checks.get('branch_protection', True)} == False    Append To List    ${missing}    Branch Protection
            IF    len(@{missing}) > 0
                ${missing_str}=    Evaluate    ", ".join(${missing})
                ${cf_summary}=    Set Variable    ${cf_summary}\n${repo_name} — missing ${missing_str} (health: ${repo_health})
                ${cf_issue_count}=    Evaluate    ${cf_issue_count} + 1
            END
        END
        IF    ${cf_issue_count} > 0
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Repositories should have standard config files and protections
            ...    actual=${cf_issue_count} repositories have configuration gaps
            ...    title=${cf_issue_count} Repos With Configuration Gaps
            ...    reproduce_hint=Review repository settings in the report
            ...    details=${cf_summary}
            ...    next_steps=Add missing files to affected repos\nEnable branch protection on default branches\nImprove community profiles
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Repository Config Health Report:\n${config_result.stdout}

Check Release Health and Cadence
    [Documentation]    Checks release frequency, identifies repos without releases, and flags overdue releases based on unreleased commit volume.
    [Tags]    github    releases    cadence    multi-repo    multi-org    access:read-only    data:config
    ${release_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_release_health.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    secret__GITHUB_APP_ID=${GITHUB_APP_ID}
    ...    secret__GITHUB_APP_INSTALLATION_ID=${GITHUB_APP_INSTALLATION_ID}
    ...    secret__GITHUB_APP_CLIENT_ID=${GITHUB_APP_CLIENT_ID}
    ...    secret__GITHUB_APP_PRIVATE_KEY=${GITHUB_APP_PRIVATE_KEY}
    ...    include_in_history=false
    ...    timeout_seconds=300
    ...    show_in_rwl_cheatsheet=true
    TRY
        ${release_data}=    Evaluate    json.loads(r'''${release_result.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty.    WARN
        ${release_data}=    Create Dictionary
    END
    ${release_details}=    Set Variable    ${release_data.get('release_details', [])}
    IF    len(@{release_details}) > 0
        ${no_release}=    Set Variable    
        ${overdue}=    Set Variable    
        ${no_count}=    Set Variable    0
        ${ov_count}=    Set Variable    0
        FOR    ${rel}    IN    @{release_details}
            ${is_overdue}=    Set Variable    ${rel.get('release_overdue', False)}
            ${days_since}=    Set Variable    ${rel.get('days_since_release', 0)}
            ${commits_behind}=    Set Variable    ${rel.get('commits_since_release', 0)}
            ${repo_name}=    Set Variable    ${rel['repository']}
            IF    ${is_overdue} == True
                ${overdue}=    Set Variable    ${overdue}\n${repo_name} — ${commits_behind} commits since last release (${days_since} days ago)
                ${ov_count}=    Evaluate    ${ov_count} + 1
            ELSE
                ${last_rel}=    Set Variable    ${rel.get('last_release', None)}
                IF    """${last_rel}""" == "None"
                    ${no_release}=    Set Variable    ${no_release}\n${repo_name} — no releases found
                    ${no_count}=    Evaluate    ${no_count} + 1
                END
            END
        END
        IF    ${ov_count} > 0
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Repos should have regular releases
            ...    actual=${ov_count} repos have overdue releases
            ...    title=${ov_count} Repos With Overdue Releases
            ...    reproduce_hint=Check releases in the report
            ...    details=${overdue}
            ...    next_steps=Tag new releases for overdue repos\nSet up automated release workflows
        END
        IF    ${no_count} > 0
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Repos should have releases or tags
            ...    actual=${no_count} repos have no releases
            ...    title=${no_count} Repos Without Releases
            ...    reproduce_hint=Check repos in the report
            ...    details=${no_release}
            ...    next_steps=Create initial releases for repos lacking them\nConsider whether repos need release management
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Release Health Report:\n${release_result.stdout}

Generate Contributor Activity Pulse
    [Documentation]    Builds a per-person activity summary: commits, PRs, review bottlenecks, and who is waiting on whom.
    [Tags]    github    contributors    pulse    review-bottleneck    multi-repo    multi-org    access:read-only    data:config
    ${pulse_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_contributor_pulse.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    secret__GITHUB_APP_ID=${GITHUB_APP_ID}
    ...    secret__GITHUB_APP_INSTALLATION_ID=${GITHUB_APP_INSTALLATION_ID}
    ...    secret__GITHUB_APP_CLIENT_ID=${GITHUB_APP_CLIENT_ID}
    ...    secret__GITHUB_APP_PRIVATE_KEY=${GITHUB_APP_PRIVATE_KEY}
    ...    include_in_history=false
    ...    timeout_seconds=300
    ...    show_in_rwl_cheatsheet=true
    TRY
        ${pulse_data}=    Evaluate    json.loads(r'''${pulse_result.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty.    WARN
        ${pulse_data}=    Create Dictionary
    END
    ${bottlenecks}=    Set Variable    ${pulse_data.get('review_bottlenecks', [])}
    ${contributors}=    Set Variable    ${pulse_data.get('contributors', [])}
    ${waiting_on}=    Set Variable    ${pulse_data.get('waiting_on_summary', {})}
    IF    len(@{bottlenecks}) > 0
        FOR    ${bottleneck}    IN    @{bottlenecks}
            ${not_responded}=    Set Variable    ${bottleneck.get('reviewers_who_have_not_responded', [])}
            ${not_responded_str}=    Evaluate    ", ".join(${not_responded}) if ${not_responded} else "unknown"
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=PR #${bottleneck['pr_number']} ("${bottleneck['title']}") should receive reviews
            ...    actual=PR by ${bottleneck['author']} is blocked waiting on review from: ${not_responded_str}
            ...    title=Review Bottleneck: `${bottleneck['title']}` waiting on ${not_responded_str}
            ...    reproduce_hint=Visit ${bottleneck['html_url']}
            ...    details=Author: ${bottleneck['author']}\nRepository: ${bottleneck['repository']}\nDays open: ${bottleneck['days_open']}\nNot responded: ${not_responded_str}
            ...    next_steps=Ping ${not_responded_str} for review\nAssign alternate reviewers\nEscalate if no response in 48h
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Contributor Pulse Report:\n${pulse_result.stdout}


*** Keywords ***
Suite Initialization
    ${GITHUB_TOKEN}=    RW.Core.Import Secret    GITHUB_TOKEN    optional=True
    ${GITHUB_TOKEN}=    Set Variable If    """${GITHUB_TOKEN}""" == "None"    ${EMPTY}    ${GITHUB_TOKEN}
    ${GITHUB_APP_ID}=    RW.Core.Import Secret    GITHUB_APP_ID    optional=True
    ${GITHUB_APP_ID}=    Set Variable If    """${GITHUB_APP_ID}""" == "None"    ${EMPTY}    ${GITHUB_APP_ID}
    ${GITHUB_APP_INSTALLATION_ID}=    RW.Core.Import Secret    GITHUB_APP_INSTALLATION_ID    optional=True
    ${GITHUB_APP_INSTALLATION_ID}=    Set Variable If    """${GITHUB_APP_INSTALLATION_ID}""" == "None"    ${EMPTY}    ${GITHUB_APP_INSTALLATION_ID}
    ${GITHUB_APP_CLIENT_ID}=    RW.Core.Import Secret    GITHUB_APP_CLIENT_ID    optional=True
    ${GITHUB_APP_CLIENT_ID}=    Set Variable If    """${GITHUB_APP_CLIENT_ID}""" == "None"    ${EMPTY}    ${GITHUB_APP_CLIENT_ID}
    ${GITHUB_APP_PRIVATE_KEY}=    RW.Core.Import Secret    GITHUB_APP_PRIVATE_KEY    optional=True
    ${GITHUB_APP_PRIVATE_KEY}=    Set Variable If    """${GITHUB_APP_PRIVATE_KEY}""" == "None"    ${EMPTY}    ${GITHUB_APP_PRIVATE_KEY}
    ${GITHUB_REPOS}=    RW.Core.Import User Variable    GITHUB_REPOS
    ...    type=string
    ...    description=Comma-separated list of GitHub repositories in format owner/repo, or 'ALL' for all org repositories
    ...    pattern=\w*
    ...    example=org/api,org/frontend
    ...    default=ALL
    ${GITHUB_ORGS}=    RW.Core.Import User Variable    GITHUB_ORGS
    ...    type=string
    ...    description=GitHub organization names (single org or comma-separated list for multiple orgs)
    ...    pattern=\w*
    ...    example=my-org
    ...    default=
    ${GITHUB_ORGS}=    Set Variable If    """${GITHUB_ORGS}""" == "None"    ${EMPTY}    ${GITHUB_ORGS}
    ${DORMANT_DAYS}=    RW.Core.Import User Variable    DORMANT_DAYS
    ...    type=string
    ...    description=Number of days without a push before a repository is considered dormant
    ...    pattern=^\d+$
    ...    example=90
    ...    default=90
    ${STALE_ISSUE_DAYS}=    RW.Core.Import User Variable    STALE_ISSUE_DAYS
    ...    type=string
    ...    description=Number of days without an update before an issue is considered stale
    ...    pattern=^\d+$
    ...    example=60
    ...    default=60
    ${STALE_ISSUE_THRESHOLD}=    RW.Core.Import User Variable    STALE_ISSUE_THRESHOLD
    ...    type=string
    ...    description=Total stale issues across repos before raising an alert
    ...    pattern=^\d+$
    ...    example=20
    ...    default=20
    ${STALE_PR_DAYS}=    RW.Core.Import User Variable    STALE_PR_DAYS
    ...    type=string
    ...    description=Number of days open before a PR is considered stale
    ...    pattern=^\d+$
    ...    example=14
    ...    default=14
    ${STALE_BRANCH_DAYS}=    RW.Core.Import User Variable    STALE_BRANCH_DAYS
    ...    type=string
    ...    description=Number of days since last commit before a branch is considered stale
    ...    pattern=^\d+$
    ...    example=60
    ...    default=60
    ${OVERDUE_COMMIT_THRESHOLD}=    RW.Core.Import User Variable    OVERDUE_COMMIT_THRESHOLD
    ...    type=string
    ...    description=Number of unreleased commits before a release is considered overdue
    ...    pattern=^\d+$
    ...    example=30
    ...    default=30
    ${PULSE_DAYS}=    RW.Core.Import User Variable    PULSE_DAYS
    ...    type=string
    ...    description=Number of days to look back for contributor activity pulse
    ...    pattern=^\d+$
    ...    example=7
    ...    default=7
    ${MAX_REPOS_TO_ANALYZE}=    RW.Core.Import User Variable    MAX_REPOS_TO_ANALYZE
    ...    type=string
    ...    description=Maximum number of repositories to analyze when GITHUB_REPOS is 'ALL' (0 for unlimited)
    ...    pattern=^\d+$
    ...    example=50
    ...    default=0
    ${MAX_REPOS_PER_ORG}=    RW.Core.Import User Variable    MAX_REPOS_PER_ORG
    ...    type=string
    ...    description=Maximum number of repositories to analyze per organization when using 'ALL' (0 for unlimited)
    ...    pattern=^\d+$
    ...    example=25
    ...    default=0

    Set Suite Variable    ${GITHUB_TOKEN}    ${GITHUB_TOKEN}
    Set Suite Variable    ${GITHUB_APP_ID}    ${GITHUB_APP_ID}
    Set Suite Variable    ${GITHUB_APP_INSTALLATION_ID}    ${GITHUB_APP_INSTALLATION_ID}
    Set Suite Variable    ${GITHUB_APP_CLIENT_ID}    ${GITHUB_APP_CLIENT_ID}
    Set Suite Variable    ${GITHUB_APP_PRIVATE_KEY}    ${GITHUB_APP_PRIVATE_KEY}
    Set Suite Variable    ${GITHUB_REPOS}    ${GITHUB_REPOS}
    Set Suite Variable    ${GITHUB_ORGS}    ${GITHUB_ORGS}
    Set Suite Variable    ${DORMANT_DAYS}    ${DORMANT_DAYS}
    Set Suite Variable    ${STALE_ISSUE_DAYS}    ${STALE_ISSUE_DAYS}
    Set Suite Variable    ${STALE_ISSUE_THRESHOLD}    ${STALE_ISSUE_THRESHOLD}
    Set Suite Variable    ${STALE_PR_DAYS}    ${STALE_PR_DAYS}
    Set Suite Variable    ${STALE_BRANCH_DAYS}    ${STALE_BRANCH_DAYS}
    Set Suite Variable    ${OVERDUE_COMMIT_THRESHOLD}    ${OVERDUE_COMMIT_THRESHOLD}
    Set Suite Variable    ${PULSE_DAYS}    ${PULSE_DAYS}
    Set Suite Variable    ${MAX_REPOS_TO_ANALYZE}    ${MAX_REPOS_TO_ANALYZE}
    Set Suite Variable    ${MAX_REPOS_PER_ORG}    ${MAX_REPOS_PER_ORG}
    Set Suite Variable    ${env}    {"GITHUB_REPOS":"${GITHUB_REPOS}", "GITHUB_ORGS":"${GITHUB_ORGS}", "DORMANT_DAYS":"${DORMANT_DAYS}", "STALE_ISSUE_DAYS":"${STALE_ISSUE_DAYS}", "STALE_ISSUE_THRESHOLD":"${STALE_ISSUE_THRESHOLD}", "STALE_PR_DAYS":"${STALE_PR_DAYS}", "STALE_BRANCH_DAYS":"${STALE_BRANCH_DAYS}", "OVERDUE_COMMIT_THRESHOLD":"${OVERDUE_COMMIT_THRESHOLD}", "PULSE_DAYS":"${PULSE_DAYS}", "MAX_REPOS_TO_ANALYZE":"${MAX_REPOS_TO_ANALYZE}", "MAX_REPOS_PER_ORG":"${MAX_REPOS_PER_ORG}"}