*** Settings ***
Documentation       This taskset collects information about Jenkins health and failed builds
...                to help troubleshoot potential issues.
Metadata            Author    saurabh3460
Metadata            Display Name    Jenkins Healthcheck
Metadata            Supports    Jenkins

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform


Suite Setup         Suite Initialization

*** Tasks ***
Check Failed Jenkins Builds
    [Documentation]    Check Failed Jenkins Builds
    [Tags]    Jenkins    Logs    Builds
    ${rsp}=    RW.CLI.Run Bash File
    ...    bash_file=faild_build_logs.sh
    ...    env=${env}
    ...    include_in_history=False
    ...    secret__jenkins_token=${JENKINS_TOKEN}
    ...    secret__jenkins_username=${JENKINS_USERNAME}
    TRY
        ${jobs}=    Evaluate    json.loads(r'''${rsp.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${jobs}=    Create List
    END
    ${failed_builds}=    Evaluate    len(@{jobs})
    ${failed_builds_score}=    Evaluate    1 if int(${failed_builds}) <= int(${MAX_FAILED_BUILDS}) else 0
    Set Global Variable    ${failed_builds_score}

Check For Long Running Builds
    [Documentation]    Check Jenkins builds that have been running longer than a specified threshold
    [Tags]    Jenkins    Builds
    ${rsp}=    RW.CLI.Run Bash File
    ...    bash_file=long_running_builds.sh
    ...    cmd_override=./long_running_builds.sh ${TIME_THRESHOLD}
    ...    env=${env}
    ...    include_in_history=False
    ...    secret__jenkins_token=${JENKINS_TOKEN}
    ...    secret__jenkins_username=${JENKINS_USERNAME}
    TRY
        ${data}=    Evaluate    json.loads(r'''${rsp.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty object.    WARN
        ${data}=    Create Dictionary
    END

    ${long_running_builds}=    Set Variable    ${data.get('long_running_jobs', [])}
    ${long_running_count}=    Evaluate    len($long_running_builds)

    ${long_running_score}=    Evaluate    1 if int(${long_running_count}) <= int(${MAX_LONG_RUNNING_BUILDS}) else 0
    Set Global Variable    ${long_running_score}

Generate Health Score
    ${health_score}=      Evaluate  (${failed_builds_score} + ${long_running_score}) / 2
    ${health_score}=      Convert to Number    ${health_score}  2
    RW.Core.Push Metric    ${health_score}


*** Keywords ***
Suite Initialization
    ${JENKINS_URL}=    RW.Core.Import User Variable    JENKINS_URL
    ...    type=string
    ...    description=The URL of your Jenkins instance
    ...    pattern=\w*
    ...    example=https://jenkins.example.com
    ${JENKINS_USERNAME}=    RW.Core.Import Secret    JENKINS_USERNAME
    ...    type=string
    ...    description=Jenkins username for authentication
    ...    pattern=\w*
    ...    example=admin
    ${JENKINS_TOKEN}=    RW.Core.Import Secret    JENKINS_TOKEN
    ...    type=string
    ...    description=Jenkins API token for authentication
    ...    pattern=\w*
    ...    example=11aa22bb33cc44dd55ee66ff77gg88hh
    ${TIME_THRESHOLD}=    RW.Core.Import User Variable    TIME_THRESHOLD
    ...    type=string
    ...    description=The threshold for long running builds, formats like '5m', '2h', '1d' or '5min', '2h', '1d'
    ...    pattern=\d+
    ...    example="1m"
    ...    default="1m"
    ${MAX_FAILED_BUILDS}=    RW.Core.Import User Variable    MAX_FAILED_BUILDS
    ...    type=string
    ...    description=The maximum number of failed builds to consider healthy
    ...    pattern=\d+
    ...    example="1"
    ...    default="0"
    ${MAX_LONG_RUNNING_BUILDS}=    RW.Core.Import User Variable    MAX_LONG_RUNNING_BUILDS
    ...    type=string
    ...    description=The maximum number of long running builds to consider healthy
    ...    pattern=\d+
    ...    example="1"
    ...    default="0"
    Set Suite Variable    ${env}    {"JENKINS_URL":"${JENKINS_URL}"}
    Set Suite Variable    ${JENKINS_URL}    ${JENKINS_URL}
    Set Suite Variable    ${JENKINS_USERNAME}    ${JENKINS_USERNAME}
    Set Suite Variable    ${JENKINS_TOKEN}    ${JENKINS_TOKEN}
    Set Suite Variable    ${TIME_THRESHOLD}    ${TIME_THRESHOLD}
    Set Suite Variable    ${MAX_FAILED_BUILDS}    ${MAX_FAILED_BUILDS}
    Set Suite Variable    ${MAX_LONG_RUNNING_BUILDS}    ${MAX_LONG_RUNNING_BUILDS}