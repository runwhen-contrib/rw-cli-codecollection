*** Settings ***
Documentation       Comprehensive health monitoring for GitHub Actions across specified repositories and organizations
Metadata            Author    stewartshea
Metadata            Display Name    GitHub Actions Health Monitoring
Metadata            Supports    GitHub Actions

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.NextSteps
Library             OperatingSystem
Library             String

Suite Setup         Suite Initialization


*** Tasks ***
Check Recent Workflow Failures Across Specified Repositories
    [Documentation]    Analyzes recent workflow failures across the specified repositories and identifies common failure patterns
    [Tags]
    ...    github
    ...    workflow
    ...    failures
    ...    repositories
    ...    multi-repo
    ...    multi-org
    ...    access:read-only
    ${workflow_failures}=    RW.CLI.Run Bash File
    ...    bash_file=check_workflow_failures.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    include_in_history=false
    ...    timeout_seconds=300
    ...    show_in_rwl_cheatsheet=true
    TRY
        ${failures}=    Evaluate    json.loads(r'''${workflow_failures.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${failures}=    Create List
    END
    IF    len(@{failures}) > 0
        FOR    ${failure}    IN    @{failures}
            ${workflow_name}=    Set Variable    ${failure['workflow_name']}
            ${repository}=    Set Variable    ${failure['repository']}
            ${run_number}=    Set Variable    ${failure['run_number']}
            ${conclusion}=    Set Variable    ${failure['conclusion']}
            ${html_url}=    Set Variable    ${failure['html_url']}
            ${created_at}=    Set Variable    ${failure['created_at']}
            ${failure_details}=    Set Variable    ${failure.get('failure_details', 'No detailed failure information available')}
            ${issue_timestamp}=    RW.Core.Get Issue Timestamp

            RW.Core.Add Issue
            ...    severity=3
            ...    expected=GitHub workflow `${workflow_name}` in repository `${repository}` should complete successfully
            ...    actual=GitHub workflow `${workflow_name}` in repository `${repository}` failed with conclusion: ${conclusion}
            ...    title=Workflow Failure: `${workflow_name}` in ${repository} (Run #${run_number})
            ...    reproduce_hint=Visit ${html_url}
            ...    details=Workflow failed at ${created_at}\nRepository: ${repository}\nConclusion: ${conclusion}\nURL: ${html_url}\n\nFailure Details:\n${failure_details}
            ...    next_steps=Review workflow logs and fix the identified issues\nCheck for dependency conflicts or environment issues\nConsider enabling debug logging for more details
            ...    observed_at=${issue_timestamp}
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Recent Workflow Failures Analysis:\n${workflow_failures.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Check Long Running Workflows Across Specified Repositories
    [Documentation]    Identifies workflows that have been running longer than expected thresholds across the specified repositories
    [Tags]
    ...    github
    ...    workflow
    ...    performance
    ...    long-running
    ...    multi-repo
    ...    multi-org
    ...    access:read-only
    ${long_running_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=check_long_running_workflows.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    include_in_history=false
    ...    timeout_seconds=300
    ...    show_in_rwl_cheatsheet=true
    TRY
        ${long_running}=    Evaluate    json.loads(r'''${long_running_analysis.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${long_running}=    Create List
    END
    IF    len(@{long_running}) > 0
        FOR    ${workflow}    IN    @{long_running}
            ${workflow_name}=    Set Variable    ${workflow['workflow_name']}
            ${repository}=    Set Variable    ${workflow['repository']}
            ${run_number}=    Set Variable    ${workflow['run_number']}
            ${duration}=    Set Variable    ${workflow['duration_minutes']}
            ${html_url}=    Set Variable    ${workflow['html_url']}
            ${issue_timestamp}=    RW.Core.Get Issue Timestamp

            RW.Core.Add Issue
            ...    severity=4
            ...    expected=GitHub workflow `${workflow_name}` in repository `${repository}` should complete within ${MAX_WORKFLOW_DURATION_MINUTES} minutes
            ...    actual=GitHub workflow `${workflow_name}` in repository `${repository}` has been running for ${duration} minutes
            ...    title=Long Running Workflow: `${workflow_name}` in ${repository} (Run #${run_number}) - ${duration} minutes
            ...    reproduce_hint=Visit ${html_url}
            ...    details=Workflow has exceeded the expected duration threshold\nRepository: ${repository}\nCurrent duration: ${duration} minutes\nThreshold: ${MAX_WORKFLOW_DURATION_MINUTES} minutes
            ...    next_steps=Review workflow performance bottlenecks\nConsider optimizing build steps or parallelization\nCheck for hung processes or infinite loops
            ...    observed_at=${issue_timestamp}
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Long Running Workflows Analysis:\n${long_running_analysis.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Check Repository Health Summary for Specified Repositories
    [Documentation]    Provides a comprehensive health summary across the specified repositories
    [Tags]
    ...    github
    ...    repositories
    ...    health
    ...    summary
    ...    multi-repo
    ...    multi-org
    ...    access:read-only
    ${repo_health}=    RW.CLI.Run Bash File
    ...    bash_file=check_repo_health_summary.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    include_in_history=false
    ...    timeout_seconds=300
    ...    show_in_rwl_cheatsheet=true
    TRY
        ${health_data}=    Evaluate    json.loads(r'''${repo_health.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty object.    WARN
        ${health_data}=    Create Dictionary
    END
    ${failing_repos}=    Set Variable    ${health_data.get('repositories_with_failures', [])}
    ${total_failures}=    Set Variable    ${health_data.get('total_failures', 0)}
    ${health_score}=    Set Variable    ${health_data.get('overall_health_score', 1.0)}
    ${repos_analyzed}=    Set Variable    ${health_data.get('repositories_analyzed', [])}
    IF    $total_failures > ${REPO_FAILURE_THRESHOLD}
        ${issue_timestamp}=    RW.Core.Get Issue Timestamp

        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Specified repositories should have fewer than ${REPO_FAILURE_THRESHOLD} workflow failures
        ...    actual=Specified repositories have ${total_failures} workflow failures
        ...    title=High Workflow Failure Rate Across Specified Repositories
        ...    reproduce_hint=Review individual repository failures
        ...    details=Overall health score: ${health_score}\nTotal failures: ${total_failures}\nRepositories with failures: ${failing_repos}\nRepositories analyzed: ${repos_analyzed}
        ...    next_steps=Review failing repositories and address common failure patterns\nCheck for organization-wide infrastructure issues\nConsider implementing stricter CI/CD policies
        ...    observed_at=${issue_timestamp}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Repository Health Summary:\n${repo_health.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Check GitHub Actions Runner Health Across Specified Organizations
    [Documentation]    Monitors the health and availability of GitHub Actions runners across the specified organizations
    [Tags]
    ...    github
    ...    runners
    ...    self-hosted
    ...    health
    ...    multi-org
    ...    access:read-only
    ${runner_health}=    RW.CLI.Run Bash File
    ...    bash_file=check_runner_health.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    include_in_history=false
    ...    timeout_seconds=300
    ...    show_in_rwl_cheatsheet=true
    TRY
        ${runners}=    Evaluate    json.loads(r'''${runner_health.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty object.    WARN
        ${runners}=    Create Dictionary
    END
    ${offline_runners}=    Set Variable    ${runners.get('offline_runners', [])}
    ${busy_runners}=    Set Variable    ${runners.get('busy_runners', [])}
    ${total_runners}=    Set Variable    ${runners.get('total_runners', 0)}
    ${organizations_analyzed}=    Set Variable    ${runners.get('organizations_analyzed', [])}
    IF    len(@{offline_runners}) > 0
        FOR    ${runner}    IN    @{offline_runners}
            ${runner_name}=    Set Variable    ${runner['name']}
            ${status}=    Set Variable    ${runner['status']}
            ${organization}=    Set Variable    ${runner['organization']}
            ${issue_timestamp}=    RW.Core.Get Issue Timestamp

            RW.Core.Add Issue
            ...    severity=3
            ...    expected=GitHub Actions runner `${runner_name}` should be online and available
            ...    actual=GitHub Actions runner `${runner_name}` is offline with status: ${status}
            ...    title=Offline GitHub Actions Runner: `${runner_name}` in ${organization}
            ...    reproduce_hint=Check runner status in GitHub organization settings
            ...    details=Runner status: ${status}\nOrganization: ${organization}\nRunner may need to be restarted or reconnected
            ...    next_steps=Restart the GitHub Actions runner service\nCheck network connectivity\nVerify runner registration token
            ...    observed_at=${issue_timestamp}
        END
    END
    ${runner_utilization}=    Evaluate    len(@{busy_runners}) / max(${total_runners}, 1) * 100 if ${total_runners} > 0 else 0
    IF    $runner_utilization > ${HIGH_RUNNER_UTILIZATION_THRESHOLD}
        ${issue_timestamp}=    RW.Core.Get Issue Timestamp

        RW.Core.Add Issue
        ...    severity=4
        ...    expected=GitHub Actions runner utilization should be below ${HIGH_RUNNER_UTILIZATION_THRESHOLD}%
        ...    actual=GitHub Actions runner utilization is ${runner_utilization}%
        ...    title=High Runner Utilization Across Organizations
        ...    reproduce_hint=Check runner capacity and workflow queue
        ...    details=Current utilization: ${runner_utilization}%\nBusy runners: ${len(@{busy_runners})}\nTotal runners: ${total_runners}\nOrganizations: ${organizations_analyzed}
        ...    next_steps=Consider adding more runners\nOptimize workflow resource usage\nImplement workflow prioritization\nBalance workload across organizations
        ...    observed_at=${issue_timestamp}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Runner Health Analysis:\n${runner_health.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Check Security Workflow Status Across Specified Repositories
    [Documentation]    Monitors security-related workflows and dependency scanning results across the specified repositories
    [Tags]
    ...    github
    ...    security
    ...    vulnerability
    ...    workflow
    ...    multi-repo
    ...    multi-org
    ...    access:read-only
    ${security_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=check_security_workflows.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    include_in_history=false
    ...    timeout_seconds=300
    ...    show_in_rwl_cheatsheet=true
    TRY
        ${security_data}=    Evaluate    json.loads(r'''${security_analysis.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty object.    WARN
        ${security_data}=    Create Dictionary
    END
    ${security_alerts}=    Set Variable    ${security_data.get('security_alerts_by_repo', {})}
    ${failed_security_workflows}=    Set Variable    ${security_data.get('failed_security_workflows', [])}
    ${total_critical_vulns}=    Set Variable    ${security_data.get('total_critical_vulnerabilities', 0)}
    IF    $total_critical_vulns > 0
        ${issue_timestamp}=    RW.Core.Get Issue Timestamp

        RW.Core.Add Issue
        ...    severity=1
        ...    expected=Specified repositories should not have critical security vulnerabilities
        ...    actual=Found ${total_critical_vulns} critical security vulnerabilities across specified repositories
        ...    title=Critical Security Vulnerabilities Found Across Repositories
        ...    reproduce_hint=Check GitHub Security tabs for each repository
        ...    details=Total critical vulnerabilities: ${total_critical_vulns}\nReview security alerts by repository: ${security_alerts}
        ...    next_steps=Immediately address critical vulnerabilities\nUpdate vulnerable dependencies\nReview security advisory recommendations\nImplement automated security scanning
        ...    observed_at=${issue_timestamp}
    END
    IF    len(@{failed_security_workflows}) > 0
        FOR    ${workflow}    IN    @{failed_security_workflows}
            ${workflow_name}=    Set Variable    ${workflow['name']}
            ${repository}=    Set Variable    ${workflow['repository']}
            ${conclusion}=    Set Variable    ${workflow['conclusion']}
            ${issue_timestamp}=    RW.Core.Get Issue Timestamp

            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Security workflow `${workflow_name}` in repository `${repository}` should complete successfully
            ...    actual=Security workflow `${workflow_name}` in repository `${repository}` failed with conclusion: ${conclusion}
            ...    title=Failed Security Workflow: `${workflow_name}` in ${repository}
            ...    reproduce_hint=Review workflow run logs
            ...    details=Security workflow failed\nRepository: ${repository}\nConclusion: ${conclusion}
            ...    next_steps=Review security workflow configuration\nCheck for updated security scanning tools\nFix identified security issues\nEnsure security tools have proper permissions
            ...    observed_at=${issue_timestamp}
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Security Workflow Analysis:\n${security_analysis.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Check GitHub Actions Billing and Usage Across Specified Organizations
    [Documentation]    Monitors GitHub Actions usage patterns and potential billing concerns across the specified organizations
    [Tags]
    ...    github
    ...    billing
    ...    usage
    ...    organizations
    ...    multi-org
    ...    access:read-only
    ${billing_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=check_billing_usage.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    include_in_history=false
    ...    timeout_seconds=300
    ...    show_in_rwl_cheatsheet=true
    TRY
        ${billing_data}=    Evaluate    json.loads(r'''${billing_analysis.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty object.    WARN
        ${billing_data}=    Create Dictionary
    END
    ${total_usage_minutes}=    Set Variable    ${billing_data.get('total_usage_minutes', 0)}
    ${total_included_minutes}=    Set Variable    ${billing_data.get('total_included_minutes', 0)}
    ${organizations_analyzed}=    Set Variable    ${billing_data.get('organizations_analyzed', [])}
    ${usage_percentage}=    Evaluate    ${total_usage_minutes} / max(${total_included_minutes}, 1) * 100 if ${total_included_minutes} > 0 else 0
    IF    $usage_percentage > ${HIGH_USAGE_THRESHOLD}
        ${issue_timestamp}=    RW.Core.Get Issue Timestamp

        RW.Core.Add Issue
        ...    severity=4
        ...    expected=GitHub Actions usage should be below ${HIGH_USAGE_THRESHOLD}% of included minutes
        ...    actual=GitHub Actions usage is ${usage_percentage}% of included minutes across organizations
        ...    title=High GitHub Actions Usage Across Organizations
        ...    reproduce_hint=Check billing settings in GitHub organizations
        ...    details=Total usage: ${total_usage_minutes} minutes\nTotal included minutes: ${total_included_minutes}\nUsage percentage: ${usage_percentage}%\nOrganizations: ${organizations_analyzed}
        ...    next_steps=Review workflow efficiency across organizations\nOptimize build times\nConsider usage policies\nMonitor for unusual activity\nAnalyze top consuming repositories and organizations
        ...    observed_at=${issue_timestamp}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Billing and Usage Analysis:\n${billing_analysis.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Check GitHub API Rate Limits
    [Documentation]    Monitors GitHub API rate limit usage to prevent throttling during health checks
    [Tags]
    ...    github
    ...    api
    ...    rate-limit
    ...    monitoring
    ...    access:read-only
    ${rate_limit_check}=    RW.CLI.Run Bash File
    ...    bash_file=check_rate_limits.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    include_in_history=false
    ...    timeout_seconds=60
    ...    show_in_rwl_cheatsheet=true
    TRY
        ${rate_data}=    Evaluate    json.loads(r'''${rate_limit_check.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty object.    WARN
        ${rate_data}=    Create Dictionary
    END
    ${core_remaining}=    Set Variable    ${rate_data.get('core', {}).get('remaining', 0)}
    ${core_limit}=    Set Variable    ${rate_data.get('core', {}).get('limit', 5000)}
    ${core_used}=    Set Variable    ${rate_data.get('core', {}).get('used', 0)}
    ${usage_percentage}=    Set Variable    ${rate_data.get('core', {}).get('usage_percentage', 0)}
    IF    $usage_percentage > ${RATE_LIMIT_WARNING_THRESHOLD}
        ${issue_timestamp}=    RW.Core.Get Issue Timestamp

        RW.Core.Add Issue
        ...    severity=3
        ...    expected=GitHub API rate limit usage should be below ${RATE_LIMIT_WARNING_THRESHOLD}%
        ...    actual=GitHub API rate limit usage is ${usage_percentage}%
        ...    title=High GitHub API Rate Limit Usage
        ...    reproduce_hint=Check current API usage patterns
        ...    details=Remaining requests: ${core_remaining}\nTotal limit: ${core_limit}\nUsage: ${usage_percentage}%
        ...    next_steps=Reduce API request frequency\nImplement request caching\nConsider using GraphQL API\nSpread requests over time\nOptimize health check frequency
        ...    observed_at=${issue_timestamp}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    GitHub API Rate Limit Status:\n${rate_limit_check.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}


*** Keywords ***
Suite Initialization
    ${GITHUB_TOKEN}=    RW.Core.Import Secret    GITHUB_TOKEN
    ...    type=string
    ...    description=GitHub Personal Access Token with appropriate permissions
    ...    pattern=\w*
    ...    example=ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
    ${GITHUB_REPOS}=    RW.Core.Import User Variable    GITHUB_REPOS
    ...    type=string
    ...    description=Comma-separated list of GitHub repositories in format owner/repo, or 'ALL' for all org repositories
    ...    pattern=\w*
    ...    example=microsoft/vscode,microsoft/typescript,microsoft/playwright
    ...    default=ALL
    ${GITHUB_ORGS}=    RW.Core.Import User Variable    GITHUB_ORGS
    ...    type=string
    ...    description=GitHub organization names (single org or comma-separated list for multiple orgs)
    ...    pattern=\w*
    ...    example=microsoft,github,docker
    ...    default=""
    ${MAX_WORKFLOW_DURATION_MINUTES}=    RW.Core.Import User Variable    MAX_WORKFLOW_DURATION_MINUTES
    ...    type=string
    ...    description=Maximum expected workflow duration in minutes
    ...    pattern=^\d+$
    ...    example=60
    ...    default=60
    ${REPO_FAILURE_THRESHOLD}=    RW.Core.Import User Variable    REPO_FAILURE_THRESHOLD
    ...    type=string
    ...    description=Maximum number of workflow failures allowed across specified repositories
    ...    pattern=^\d+$
    ...    example=10
    ...    default=10
    ${HIGH_RUNNER_UTILIZATION_THRESHOLD}=    RW.Core.Import User Variable    HIGH_RUNNER_UTILIZATION_THRESHOLD
    ...    type=string
    ...    description=Threshold percentage for high runner utilization warning
    ...    pattern=^\d+$
    ...    example=80
    ...    default=80
    ${HIGH_USAGE_THRESHOLD}=    RW.Core.Import User Variable    HIGH_USAGE_THRESHOLD
    ...    type=string
    ...    description=Threshold percentage for high billing usage warning
    ...    pattern=^\d+$
    ...    example=80
    ...    default=80
    ${RATE_LIMIT_WARNING_THRESHOLD}=    RW.Core.Import User Variable    RATE_LIMIT_WARNING_THRESHOLD
    ...    type=string
    ...    description=Threshold percentage for GitHub API rate limit warning
    ...    pattern=^\d+$
    ...    example=70
    ...    default=70
    ${FAILURE_LOOKBACK_DAYS}=    RW.Core.Import User Variable    FAILURE_LOOKBACK_DAYS
    ...    type=string
    ...    description=Number of days to look back for workflow failures. Accepts partial numbers (e.g. 0.04 = 1h)
    ...    pattern=^\d+$
    ...    example=1
    ...    default=1
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
    Set Suite Variable    ${GITHUB_REPOS}    ${GITHUB_REPOS}
    Set Suite Variable    ${GITHUB_ORGS}    ${GITHUB_ORGS}
    Set Suite Variable    ${MAX_WORKFLOW_DURATION_MINUTES}    ${MAX_WORKFLOW_DURATION_MINUTES}
    Set Suite Variable    ${REPO_FAILURE_THRESHOLD}    ${REPO_FAILURE_THRESHOLD}
    Set Suite Variable    ${HIGH_RUNNER_UTILIZATION_THRESHOLD}    ${HIGH_RUNNER_UTILIZATION_THRESHOLD}
    Set Suite Variable    ${HIGH_USAGE_THRESHOLD}    ${HIGH_USAGE_THRESHOLD}
    Set Suite Variable    ${RATE_LIMIT_WARNING_THRESHOLD}    ${RATE_LIMIT_WARNING_THRESHOLD}
    Set Suite Variable    ${FAILURE_LOOKBACK_DAYS}    ${FAILURE_LOOKBACK_DAYS}
    Set Suite Variable    ${MAX_REPOS_TO_ANALYZE}    ${MAX_REPOS_TO_ANALYZE}
    Set Suite Variable    ${MAX_REPOS_PER_ORG}    ${MAX_REPOS_PER_ORG}
    Set Suite Variable
    ...    ${env}
    ...    {"GITHUB_REPOS":"${GITHUB_REPOS}", "GITHUB_ORGS":"${GITHUB_ORGS}", "MAX_WORKFLOW_DURATION_MINUTES":"${MAX_WORKFLOW_DURATION_MINUTES}", "REPO_FAILURE_THRESHOLD":"${REPO_FAILURE_THRESHOLD}", "HIGH_RUNNER_UTILIZATION_THRESHOLD":"${HIGH_RUNNER_UTILIZATION_THRESHOLD}", "HIGH_USAGE_THRESHOLD":"${HIGH_USAGE_THRESHOLD}", "RATE_LIMIT_WARNING_THRESHOLD":"${RATE_LIMIT_WARNING_THRESHOLD}", "FAILURE_LOOKBACK_DAYS":"${FAILURE_LOOKBACK_DAYS}", "MAX_REPOS_TO_ANALYZE":"${MAX_REPOS_TO_ANALYZE}", "MAX_REPOS_PER_ORG":"${MAX_REPOS_PER_ORG}"}
    
    # Validate GitHub API authentication
    ${auth_test}=    RW.CLI.Run Cli
    ...    cmd=curl -sS -H "Authorization: token $GITHUB_TOKEN" -H "Accept: application/vnd.github.v3+json" "https://api.github.com/user"
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    include_in_history=false
    ...    timeout_seconds=30
    TRY
        ${auth_response}=    Evaluate    json.loads(r'''${auth_test.stdout}''')    json
        ${github_user}=    Set Variable    ${auth_response.get('login', 'unknown')}
        Log    GitHub API authentication successful for user: ${github_user}    INFO
    EXCEPT
        ${issue_timestamp}=    RW.Core.Get Issue Timestamp

        RW.Core.Add Issue
        ...    severity=1
        ...    expected=GitHub API authentication should succeed with provided GITHUB_TOKEN
        ...    actual=GitHub API authentication failed - invalid token or network issue
        ...    title=GitHub API Authentication Failed
        ...    reproduce_hint=Check that GITHUB_TOKEN is valid and has required permissions
        ...    details=API Response: ${auth_test.stdout}\nError: Failed to authenticate with GitHub API. This will cause all GitHub Actions health checks to fail.
        ...    next_steps=Verify GITHUB_TOKEN is correct and not expired\nEnsure token has required scopes: repo, actions:read, read:org\nCheck network connectivity to api.github.com\nTest token manually: curl -H "Authorization: token YOUR_TOKEN" https://api.github.com/user
            ...    observed_at=${issue_timestamp}
        Fail    GitHub API authentication failed - cannot proceed with health checks
    END 