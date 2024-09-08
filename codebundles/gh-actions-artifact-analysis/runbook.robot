*** Settings ***
Documentation       This taskset fetches the latest GitHub Actions worflow run artifact and analyzes the results with a user provided command.
Metadata            Author    stewartshea
Metadata            Display Name    GitHub Actions Artifact Analysis
Metadata            Supports    GitHub Actions

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Analyze artifact output from GitHub workflow `${WORKFLOW_NAME}` in repository `${GITHUB_REPO}`
    [Documentation]    Check GitHub workflow status and analyze artifact with a user provided command.
    [Tags]    github    workflow    actions    artifact    report
    ${ESCAPED_ANALYSIS_COMMAND}=    RW.CLI.Escape Bash Command    ${ANALYSIS_COMMAND}
    Log    ${ESCAPED_ANALYSIS_COMMAND}
    ${workflow_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=gh_actions_artifact_analysis.sh
    ...    cmd_override=ANALYSIS_COMMAND=${ESCAPED_ANALYSIS_COMMAND} ./gh_actions_artifact_analysis.sh
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    env=${env}
    ${report}=    RW.CLI.Run CLI    cat ${SCRIPT_TMP_DIR}/report.txt
    RW.Core.Add Pre To Report    Command Stdout:\n${report.stdout}

    # Raise an Issue if needed
    ${issue_details}=    RW.CLI.Run CLI     grep -E '${ISSUE_SEARCH_STRING}' ${SCRIPT_TMP_DIR}/report.txt
    RW.Core.Add Pre To Report    Searching for the string '${ISSUE_SEARCH_STRING}':\n${issue_details.stdout}
    IF    $issue_details.stdout != ""
        RW.Core.Add Issue
        ...    severity=${ISSUE_SEVERITY}
        ...    title=${ISSUE_TITLE}
        ...    expected=''
        ...    actual=''
        ...    reproduce_hint=${workflow_analysis.cmd}
        ...    details=${report.stdout}
        ...    next_steps=${ISSUE_NEXT_STEPS}
    END
    ${last_run_health_issue_details}=    RW.CLI.Run CLI     echo "${workflow_analysis.stderr}" | grep -E 'did not complete successfully|run is older than'
    IF    $last_run_health_issue_details.stdout != ""
        RW.Core.Add Issue
        ...    severity=3
        ...    title=GitHub Workflow `${WORKFLOW_NAME}` in repository `${GITHUB_REPO}` is unhealthy
        ...    expected=''
        ...    actual=''
        ...    reproduce_hint=${workflow_analysis.cmd}
        ...    details=${last_run_health_issue_details.stdout}
        ...    next_steps=Inspect Logs for GitHub workflow `${WORKFLOW_NAME}` in repository `${GITHUB_REPO}` 
    END

*** Keywords ***
Suite Initialization
    ${GITHUB_REPO}=    RW.Core.Import User Variable    GITHUB_REPO
    ...    type=string
    ...    description=The GitHub Reposiroty to query
    ...    pattern=\w*
    ...    default=''
    ...    example=runwhen-contrib/helm-charts
    ${WORKFLOW_NAME}=    RW.Core.Import User Variable    WORKFLOW_NAME
    ...    type=string
    ...    description=The GitHub Actions workflow name.
    ...    pattern=\w*
    ...    default=''
    ...    example=Trivy Scan for Critical Vulnerabilities
    ${ARTIFACT_NAME}=    RW.Core.Import User Variable    ARTIFACT_NAME
    ...    type=string
    ...    description=The artifact to inspect.
    ...    pattern=\w*
    ...    default=''
    ...    example=trivy_aggregated_results
    ${ANALYSIS_COMMAND}=    RW.Core.Import User Variable    ANALYSIS_COMMAND
    ...    type=string
    ...    description=A command to run against the output report. Tools like jq and awk are available.
    ...    pattern=\w*
    ...    default=''
    ...    example=jq .
    ${RESULT_FILE}=    RW.Core.Import User Variable    RESULT_FILE
    ...    type=string
    ...    description=The artifact to inspect.
    ...    pattern=\w*
    ...    default=''
    ...    example=aggregated_results.json
    ${GITHUB_TOKEN}=    RW.Core.Import Secret    GITHUB_TOKEN
    ...    type=string
    ...    description=The GitHub Token used to access the repository.
    ...    pattern=\w*
    ...    default=''
    ${PERIOD_HOURS}=    RW.Core.Import User Variable    PERIOD_HOURS
    ...    type=string
    ...    description=The amount of hours to condider for a healthy last workflow run.
    ...    pattern=\w*
    ...    example=24
    ...    default=24
    ${ISSUE_SEARCH_STRING}=    RW.Core.Import User Variable    ISSUE_SEARCH_STRING
    ...    type=string
    ...    description=A string that, if found in the analysis output, will generate an Issue. 
    ...    pattern=\w*
    ...    default=ERROR|Error
    ...    example=CRITICAL
    ${ISSUE_SEVERITY}=    RW.Core.Import User Variable    ISSUE_SEVERITY
    ...    type=string
    ...    description=The severity of the issue. 1 = Critical, 2=Major, 3=Minor, 4=Informational 
    ...    pattern=\w*
    ...    default=4
    ...    example=2
    ${ISSUE_TITLE}=    RW.Core.Import User Variable    ISSUE_TITLE
    ...    type=string
    ...    description=The title of the issue. 
    ...    pattern=\w*
    ...    default=The text `${ISSUE_SEARCH_STRING}` was found in GitHub Workflow `${WORKFLOW_NAME}` in repo `${GITHUB_REPO}`
    ...    example=Critical and Fixable Vulnerabilities Found in GitHub Workflow `${WORKFLOW_NAME}`
    ${ISSUE_NEXT_STEPS}=    RW.Core.Import User Variable    ISSUE_NEXT_STEPS
    ...    type=string
    ...    description=A list of next steps to take when the Issue is raised. Use `\n` to separate items in the list.'
    ...    pattern=\w*
    ...    default=Review the log output or escalate to the service owner. 
    ...    example=Remediate security issues with container images and update Helm Chart image versions 
    ${HOME}=    RW.Core.Import User Variable    HOME
    ...    type=string
    ...    description=The home path of the runner
    ...    pattern=\w*
    ...    example=/home/runwhen
    ...    default=/home/runwhen
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GITHUB_REPO}    ${GITHUB_REPO}
    Set Suite Variable    ${WORKFLOW_NAME}    ${WORKFLOW_NAME}
    Set Suite Variable    ${ARTIFACT_NAME}    ${ARTIFACT_NAME}
    Set Suite Variable    ${RESULT_FILE}    ${RESULT_FILE}
    Set Suite Variable    ${GITHUB_TOKEN}    ${GITHUB_TOKEN}
    Set Suite Variable    ${PERIOD_HOURS}    ${PERIOD_HOURS}
    Set Suite Variable    ${ANALYSIS_COMMAND}    ${ANALYSIS_COMMAND}
    Set Suite Variable    ${ISSUE_SEARCH_STRING}    ${ISSUE_SEARCH_STRING}
    Set Suite Variable    ${ISSUE_SEVERITY}    ${ISSUE_SEVERITY}
    Set Suite Variable    ${ISSUE_TITLE}    ${ISSUE_TITLE}
    Set Suite Variable    ${ISSUE_NEXT_STEPS}    ${ISSUE_NEXT_STEPS}

    Set Suite Variable    ${HOME}    ${HOME}
    ${temp_dir}=    RW.CLI.Run Cli    cmd=mktemp -d ${HOME}/gh-actions-artifact-analysis-XXXXXXXXXX | tr -d '\n'
    Set Suite Variable    ${SCRIPT_TMP_DIR}    ${temp_dir.stdout}
    Set Suite Variable
    ...    ${env}
    ...    {"RESULT_FILE":"${RESULT_FILE}","ARTIFACT_NAME":"${ARTIFACT_NAME}","WORKFLOW_NAME":"${WORKFLOW_NAME}","GITHUB_REPO":"${GITHUB_REPO}","PERIOD_HOURS":"${PERIOD_HOURS}", "SCRIPT_TMP_DIR":"${SCRIPT_TMP_DIR}", "PATH":"$PATH:${OS_PATH}"}

Suite Teardown
    RW.CLI.Run Cli    cmd=rm -rf ${SCRIPT_TMP_DIR}
