*** Settings ***
Documentation       This SLI fetches the latest GitHub Actions worflow run artifact pushes a metric based on a user provided command.
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
Analyze artifact from GitHub Workflow `${WORKFLOW_NAME}` in repository `${GITHUB_REPO}` and push `${METRIC}` metric
    [Documentation]    Check GitHub workflow status, run a user provided analysis command, and push the metric. The analysis command should result in a single metric.
    [Tags]    github    workflow    actions    artifact    report
    ${ESCAPED_ANALYSIS_COMMAND}=    RW.CLI.Escape Bash Command    ${ANALYSIS_COMMAND}
    Log    ${ESCAPED_ANALYSIS_COMMAND}
    ${rsp}=    RW.CLI.Run Bash File
    ...    bash_file=gh_actions_artifact_analysis.sh
    ...    cmd_override=ANALYSIS_COMMAND=${ESCAPED_ANALYSIS_COMMAND} ./gh_actions_artifact_analysis.sh
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    env=${env}
    ${output}=    RW.CLI.Run CLI    cat ${SCRIPT_TMP_DIR}/report.txt
    ${metric}=    Convert to Number    ${output.stdout}    2
    RW.Core.Push Metric    ${metric}

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
    ${ANALYSIS_COMMAND}=    RW.Core.Import User Variable
    ...    ANALYSIS_COMMAND
    ...    type=string
    ...    description=A command to run against the output report. Tools like jq and awk are available. This should result in a single metric.
    ...    pattern=\w*
    ...    default=''
    ...    example=jq '.Vulnerabilities | map(select(.Severity == \"CRITICAL\")) | length'
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
    Set Suite Variable    ${HOME}    ${HOME}
    ${temp_dir}=    RW.CLI.Run Cli    cmd=mktemp -d ${HOME}/gh-actions-artifact-analysis-XXXXXXXXXX | tr -d '\n'
    Set Suite Variable    ${SCRIPT_TMP_DIR}    ${temp_dir.stdout}
    Set Suite Variable
    ...    ${env}
    ...    {"RESULT_FILE":"${RESULT_FILE}","ARTIFACT_NAME":"${ARTIFACT_NAME}","WORKFLOW_NAME":"${WORKFLOW_NAME}","GITHUB_REPO":"${GITHUB_REPO}","PERIOD_HOURS":"${PERIOD_HOURS}", "SCRIPT_TMP_DIR":"${SCRIPT_TMP_DIR}", "PATH":"$PATH:${OS_PATH}"}

Suite Teardown
    RW.CLI.Run Cli    cmd=rm -rf ${SCRIPT_TMP_DIR}
