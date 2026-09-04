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
Analyze artifact from GitHub Workflow `${WORKFLOW_NAME}` in repository `${GITHUB_REPO}` and push metric
    [Documentation]    Check GitHub workflow status, run a user provided analysis command, and push the metric. The analysis command should result in a single metric.
    [Tags]    github    workflow    actions    artifact    report    data:config
    ${ESCAPED_ANALYSIS_COMMAND}=    RW.CLI.Escape Bash Command    ${ANALYSIS_COMMAND}
    Log    ${ESCAPED_ANALYSIS_COMMAND}
    ${rsp}=    RW.CLI.Run Bash File
    ...    bash_file=gh_actions_artifact_analysis.sh
    ...    cmd_override=ANALYSIS_COMMAND=${ESCAPED_ANALYSIS_COMMAND} ./gh_actions_artifact_analysis.sh
    ...    secret__GITHUB_TOKEN=${GITHUB_TOKEN}
    ...    secret__GITHUB_APP_ID=${GITHUB_APP_ID}
    ...    secret__GITHUB_APP_INSTALLATION_ID=${GITHUB_APP_INSTALLATION_ID}
    ...    secret__GITHUB_APP_CLIENT_ID=${GITHUB_APP_CLIENT_ID}
    ...    secret__GITHUB_APP_PRIVATE_KEY=${GITHUB_APP_PRIVATE_KEY}
    ...    env=${env}
    ${output}=    RW.CLI.Run CLI    cat report.txt
    ${metric}=    Convert to Number    ${output.stdout}    2
    RW.Core.Push Metric    ${metric}    sub_name=artifact_analysis
    RW.Core.Push Metric    ${metric}
    RW.CLI.Run CLI    cmd=rm report.txt

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
    ${PERIOD_HOURS}=    RW.Core.Import User Variable    PERIOD_HOURS
    ...    type=string
    ...    description=The amount of hours to condider for a healthy last workflow run.
    ...    pattern=\w*
    ...    example=24
    ...    default=24
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GITHUB_REPO}    ${GITHUB_REPO}
    Set Suite Variable    ${WORKFLOW_NAME}    ${WORKFLOW_NAME}
    Set Suite Variable    ${ARTIFACT_NAME}    ${ARTIFACT_NAME}
    Set Suite Variable    ${RESULT_FILE}    ${RESULT_FILE}
    Set Suite Variable    ${GITHUB_TOKEN}    ${GITHUB_TOKEN}
    Set Suite Variable    ${GITHUB_APP_ID}    ${GITHUB_APP_ID}
    Set Suite Variable    ${GITHUB_APP_INSTALLATION_ID}    ${GITHUB_APP_INSTALLATION_ID}
    Set Suite Variable    ${GITHUB_APP_CLIENT_ID}    ${GITHUB_APP_CLIENT_ID}
    Set Suite Variable    ${GITHUB_APP_PRIVATE_KEY}    ${GITHUB_APP_PRIVATE_KEY}
    Set Suite Variable    ${PERIOD_HOURS}    ${PERIOD_HOURS}
    Set Suite Variable    ${ANALYSIS_COMMAND}    ${ANALYSIS_COMMAND}
    Set Suite Variable
    ...    ${env}
    ...    {"RESULT_FILE":"${RESULT_FILE}","ARTIFACT_NAME":"${ARTIFACT_NAME}","WORKFLOW_NAME":"${WORKFLOW_NAME}","GITHUB_REPO":"${GITHUB_REPO}","PERIOD_HOURS":"${PERIOD_HOURS}", "PATH":"$PATH:${OS_PATH}"}


