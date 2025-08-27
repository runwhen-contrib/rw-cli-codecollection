*** Settings ***
Documentation       Service Level Indicators for GitHub Actions Health Monitoring
Metadata            Author    stewartshea
Metadata            Display Name    GitHub Actions Health SLI
Metadata            Supports    GitHub Actions

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Calculate Workflow Success Rate Across Specified Repositories
    [Documentation]    Calculates the success rate of workflows across the specified repositories over the specified period
    [Tags]    github    workflow    success-rate    sli    multi-repo
    ${workflow_sli}=    RW.CLI.Run Bash File
    ...    bash_file=calculate_workflow_sli.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    include_in_history=false
    ...    timeout_seconds=180
    TRY
        ${sli_data}=    Evaluate    json.loads(r'''${workflow_sli.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to perfect score.    WARN
        ${sli_data}=    Create Dictionary    success_rate=1.0    total_runs=0    failed_runs=0
    END
    ${success_rate}=    Set Variable    ${sli_data.get('success_rate', 1.0)}
    ${workflow_success_score}=    Evaluate    1 if float(${success_rate}) >= float(${MIN_WORKFLOW_SUCCESS_RATE}) else 0
    Set Global Variable    ${workflow_success_score}
    RW.Core.Push Metric    ${workflow_success_score}    sub_name=workflow_success

Calculate Organization Health Score Across Specified Organizations
    [Documentation]    Calculates overall organization health score across all specified organizations
    [Tags]    github    organization    health-score    sli    multi-org
    ${org_sli}=    RW.CLI.Run Bash File
    ...    bash_file=calculate_org_sli.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    include_in_history=false
    ...    timeout_seconds=300
    TRY
        ${org_data}=    Evaluate    json.loads(r'''${org_sli.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to perfect score.    WARN
        ${org_data}=    Create Dictionary    health_score=1.0    total_repos=0    failing_repos=0
    END
    ${org_health_score}=    Set Variable    ${org_data.get('health_score', 1.0)}
    ${org_health_score_normalized}=    Evaluate    1 if float(${org_health_score}) >= float(${MIN_ORG_HEALTH_SCORE}) else 0
    Set Global Variable    ${org_health_score_normalized}
    RW.Core.Push Metric    ${org_health_score_normalized}    sub_name=org_health

Calculate Runner Availability Score Across Specified Organizations
    [Documentation]    Calculates the availability score of GitHub Actions runners across the specified organizations
    [Tags]    github    runners    availability    sli    multi-org
    ${runner_sli}=    RW.CLI.Run Bash File
    ...    bash_file=calculate_runner_sli.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    include_in_history=false
    ...    timeout_seconds=180
    TRY
        ${runner_data}=    Evaluate    json.loads(r'''${runner_sli.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to perfect score.    WARN
        ${runner_data}=    Create Dictionary    availability_score=1.0    total_runners=0    online_runners=0
    END
    ${availability_score}=    Set Variable    ${runner_data.get('availability_score', 1.0)}
    ${runner_availability_score}=    Evaluate    1 if float(${availability_score}) >= float(${MIN_RUNNER_AVAILABILITY}) else 0
    Set Global Variable    ${runner_availability_score}
    RW.Core.Push Metric    ${runner_availability_score}    sub_name=runner_availability

Calculate Security Workflow Score Across Specified Repositories
    [Documentation]    Calculates security workflow health score including vulnerability scanning across the specified repositories
    [Tags]    github    security    vulnerability    sli    multi-repo
    ${security_sli}=    RW.CLI.Run Bash File
    ...    bash_file=calculate_security_sli.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    include_in_history=false
    ...    timeout_seconds=180
    TRY
        ${security_data}=    Evaluate    json.loads(r'''${security_sli.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to perfect score.    WARN
        ${security_data}=    Create Dictionary    security_score=1.0    vulnerabilities=0    failed_security_workflows=0
    END
    ${security_score}=    Set Variable    ${security_data.get('security_score', 1.0)}
    ${critical_vulnerabilities}=    Set Variable    ${security_data.get('critical_vulnerabilities', 0)}
    ${security_workflow_score}=    Evaluate    1 if float(${security_score}) >= float(${MIN_SECURITY_SCORE}) and int(${critical_vulnerabilities}) == 0 else 0
    Set Global Variable    ${security_workflow_score}
    RW.Core.Push Metric    ${security_workflow_score}    sub_name=security_workflows

Calculate Performance Score Across Specified Repositories
    [Documentation]    Calculates workflow performance score based on execution times across the specified repositories
    [Tags]    github    performance    duration    sli    multi-repo
    ${performance_sli}=    RW.CLI.Run Bash File
    ...    bash_file=calculate_performance_sli.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    include_in_history=false
    ...    timeout_seconds=180
    TRY
        ${performance_data}=    Evaluate    json.loads(r'''${performance_sli.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to perfect score.    WARN
        ${performance_data}=    Create Dictionary    performance_score=1.0    avg_duration=0    long_running_count=0
    END
    ${performance_score}=    Set Variable    ${performance_data.get('performance_score', 1.0)}
    ${long_running_count}=    Set Variable    ${performance_data.get('long_running_count', 0)}
    ${workflow_performance_score}=    Evaluate    1 if float(${performance_score}) >= float(${MIN_PERFORMANCE_SCORE}) and int(${long_running_count}) <= int(${MAX_LONG_RUNNING_WORKFLOWS}) else 0
    Set Global Variable    ${workflow_performance_score}
    RW.Core.Push Metric    ${workflow_performance_score}    sub_name=workflow_performance

Calculate API Rate Limit Health Score
    [Documentation]    Calculates GitHub API rate limit utilization health score
    [Tags]    github    api    rate-limit    sli
    ${rate_limit_sli}=    RW.CLI.Run Bash File
    ...    bash_file=calculate_rate_limit_sli.sh
    ...    env=${env}
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    include_in_history=false
    ...    timeout_seconds=60
    TRY
        ${rate_data}=    Evaluate    json.loads(r'''${rate_limit_sli.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to perfect score.    WARN
        ${rate_data}=    Create Dictionary    usage_percentage=0    remaining=5000    limit=5000
    END
    ${usage_percentage}=    Set Variable    ${rate_data.get('usage_percentage', 0)}
    ${rate_limit_score}=    Evaluate    1 if float(${usage_percentage}) <= float(${MAX_RATE_LIMIT_USAGE}) else 0
    Set Global Variable    ${rate_limit_score}
    RW.Core.Push Metric    ${rate_limit_score}    sub_name=api_rate_limit

Generate Overall GitHub Actions Health Score
    [Documentation]    Generates a composite health score from all measured indicators
    [Tags]    github    health-score    sli    composite
    # Initialize scores to 1 if not set (meaning those checks weren't run)
    ${workflow_success_score}=    Set Variable If    '${workflow_success_score}' != '${EMPTY}'    ${workflow_success_score}    1
    ${org_health_score_normalized}=    Set Variable If    '${org_health_score_normalized}' != '${EMPTY}'    ${org_health_score_normalized}    1
    ${runner_availability_score}=    Set Variable If    '${runner_availability_score}' != '${EMPTY}'    ${runner_availability_score}    1
    ${security_workflow_score}=    Set Variable If    '${security_workflow_score}' != '${EMPTY}'    ${security_workflow_score}    1
    ${workflow_performance_score}=    Set Variable If    '${workflow_performance_score}' != '${EMPTY}'    ${workflow_performance_score}    1
    ${rate_limit_score}=    Set Variable If    '${rate_limit_score}' != '${EMPTY}'    ${rate_limit_score}    1
    
    # Calculate weighted composite score
    ${composite_score}=    Evaluate    float(${workflow_success_score}) * 0.25 + float(${org_health_score_normalized}) * 0.20 + float(${runner_availability_score}) * 0.15 + float(${security_workflow_score}) * 0.20 + float(${workflow_performance_score}) * 0.15 + float(${rate_limit_score}) * 0.05
    ${health_score}=    Convert to Number    ${composite_score}    2
    RW.Core.Push Metric    ${health_score}


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
    ...    example=microsoft/vscode,microsoft/typescript
    ...    default=ALL
    ${GITHUB_ORGS}=    RW.Core.Import User Variable    GITHUB_ORGS
    ...    type=string
    ...    description=GitHub organization names (single org or comma-separated list for multiple orgs)
    ...    pattern=\w*
    ...    example=microsoft,github
    ...    default=""
    ${MIN_WORKFLOW_SUCCESS_RATE}=    RW.Core.Import User Variable    MIN_WORKFLOW_SUCCESS_RATE
    ...    type=string
    ...    description=Minimum acceptable workflow success rate (0.0-1.0)
    ...    pattern=^\d*\.?\d+$
    ...    example=0.95
    ...    default=0.95
    ${MIN_ORG_HEALTH_SCORE}=    RW.Core.Import User Variable    MIN_ORG_HEALTH_SCORE
    ...    type=string
    ...    description=Minimum acceptable organization health score (0.0-1.0)
    ...    pattern=^\d*\.?\d+$
    ...    example=0.90
    ...    default=0.90
    ${MIN_RUNNER_AVAILABILITY}=    RW.Core.Import User Variable    MIN_RUNNER_AVAILABILITY
    ...    type=string
    ...    description=Minimum acceptable runner availability score (0.0-1.0)
    ...    pattern=^\d*\.?\d+$
    ...    example=0.95
    ...    default=0.95
    ${MIN_SECURITY_SCORE}=    RW.Core.Import User Variable    MIN_SECURITY_SCORE
    ...    type=string
    ...    description=Minimum acceptable security workflow score (0.0-1.0)
    ...    pattern=^\d*\.?\d+$
    ...    example=0.98
    ...    default=0.98
    ${MIN_PERFORMANCE_SCORE}=    RW.Core.Import User Variable    MIN_PERFORMANCE_SCORE
    ...    type=string
    ...    description=Minimum acceptable workflow performance score (0.0-1.0)
    ...    pattern=^\d*\.?\d+$
    ...    example=0.90
    ...    default=0.90
    ${MAX_RATE_LIMIT_USAGE}=    RW.Core.Import User Variable    MAX_RATE_LIMIT_USAGE
    ...    type=string
    ...    description=Maximum acceptable API rate limit usage percentage
    ...    pattern=^\d+$
    ...    example=70
    ...    default=70
    ${MAX_LONG_RUNNING_WORKFLOWS}=    RW.Core.Import User Variable    MAX_LONG_RUNNING_WORKFLOWS
    ...    type=string
    ...    description=Maximum number of long-running workflows considered healthy
    ...    pattern=^\d+$
    ...    example=2
    ...    default=2
    ${SLI_LOOKBACK_DAYS}=    RW.Core.Import User Variable    SLI_LOOKBACK_DAYS
    ...    type=string
    ...    description=Number of days to look back for SLI calculations
    ...    pattern=^\d+$
    ...    example=7
    ...    default=7
    Set Suite Variable    ${GITHUB_TOKEN}    ${GITHUB_TOKEN}
    Set Suite Variable    ${GITHUB_REPOS}    ${GITHUB_REPOS}
    Set Suite Variable    ${GITHUB_ORGS}    ${GITHUB_ORGS}
    Set Suite Variable    ${MIN_WORKFLOW_SUCCESS_RATE}    ${MIN_WORKFLOW_SUCCESS_RATE}
    Set Suite Variable    ${MIN_ORG_HEALTH_SCORE}    ${MIN_ORG_HEALTH_SCORE}
    Set Suite Variable    ${MIN_RUNNER_AVAILABILITY}    ${MIN_RUNNER_AVAILABILITY}
    Set Suite Variable    ${MIN_SECURITY_SCORE}    ${MIN_SECURITY_SCORE}
    Set Suite Variable    ${MIN_PERFORMANCE_SCORE}    ${MIN_PERFORMANCE_SCORE}
    Set Suite Variable    ${MAX_RATE_LIMIT_USAGE}    ${MAX_RATE_LIMIT_USAGE}
    Set Suite Variable    ${MAX_LONG_RUNNING_WORKFLOWS}    ${MAX_LONG_RUNNING_WORKFLOWS}
    Set Suite Variable    ${SLI_LOOKBACK_DAYS}    ${SLI_LOOKBACK_DAYS}
    Set Suite Variable
    ...    ${env}
    ...    {"GITHUB_REPOS":"${GITHUB_REPOS}", "GITHUB_ORGS":"${GITHUB_ORGS}", "MIN_WORKFLOW_SUCCESS_RATE":"${MIN_WORKFLOW_SUCCESS_RATE}", "MIN_ORG_HEALTH_SCORE":"${MIN_ORG_HEALTH_SCORE}", "MIN_RUNNER_AVAILABILITY":"${MIN_RUNNER_AVAILABILITY}", "MIN_SECURITY_SCORE":"${MIN_SECURITY_SCORE}", "MIN_PERFORMANCE_SCORE":"${MIN_PERFORMANCE_SCORE}", "MAX_RATE_LIMIT_USAGE":"${MAX_RATE_LIMIT_USAGE}", "MAX_LONG_RUNNING_WORKFLOWS":"${MAX_LONG_RUNNING_WORKFLOWS}", "SLI_LOOKBACK_DAYS":"${SLI_LOOKBACK_DAYS}"} 