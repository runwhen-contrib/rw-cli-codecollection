*** Settings ***
Documentation    Check Jenkins health, failed builds, tests and long running builds
Metadata            Author    saurabh3460
Metadata            Display Name    Jenkins Health
Metadata            Supports    Jenkins

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             util.py

Suite Setup         Suite Initialization

*** Tasks ***
Check For Failed Build Logs in Jenkins
    [Documentation]    Check For Failed Build Logs in Jenkins
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

Check For Long Running Builds in Jenkins
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

Check For Recent Failed Tests in Jenkins
    [Documentation]    Check For Recent Failed Tests in Jenkins
    [Tags]    Jenkins    Tests
    ${failed_tests}=    Get Failed Tests
    IF    len(${failed_tests}) > 0
        ${failed_test_count}=    Evaluate    sum([len(suite['test_results']) for suite in ${failed_tests}])
        ${failed_test_score}=    Evaluate    1 if int(${failed_test_count}) <= int(${MAX_FAILED_TESTS}) else 0
        Set Global Variable    ${failed_test_score}
    ELSE
        Set Global Variable    ${failed_test_score}    1
    END

Check For Jenkins Health
    [Documentation]    Check if Jenkins instance is reachable and responding
    [Tags]    Jenkins    Health
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=curl -s -u "$${JENKINS_USERNAME.key}:$${JENKINS_TOKEN.key}" "${JENKINS_URL}/api/json"
    ...    env=${env}
    ...    secret__jenkins_token=${JENKINS_TOKEN}
    ...    secret__jenkins_username=${JENKINS_USERNAME}
    TRY
        ${data}=    Evaluate    json.loads('''${rsp.stdout}''')    json
        Set Global Variable    ${jenkins_health_score}    1
    EXCEPT
        Set Global Variable    ${jenkins_health_score}    0
    END

Check For Long Queued Builds in Jenkins
    [Documentation]    Check for builds stuck in queue beyond threshold and calculate SLI score
    [Tags]    Jenkins    Queue    Builds    SLI
    ${queued_builds}=    Get Queued Builds    wait_threshold=${QUEUE_WAIT_THRESHOLD}
    ${queued_count}=    Evaluate    len(${queued_builds})
    ${queued_builds_score}=    Evaluate    1 if int(${queued_count}) <= int(${MAX_QUEUED_BUILDS}) else 0
    Set Global Variable    ${queued_builds_score}


Generate Health Score
    ${health_score}=      Evaluate  (${failed_builds_score} + ${long_running_score} + ${failed_test_score} + ${jenkins_health_score} + ${queued_builds_score}) / 5
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
    ${LONG_RUNNING_BUILD_TIME_THRESHOLD}=    RW.Core.Import User Variable    LONG_RUNNING_BUILD_TIME_THRESHOLD
    ...    type=string
    ...    description=The threshold for long running builds, formats like '5m', '2h', '1d' or '5min', '2h', '1d'
    ...    pattern=\d+
    ...    example="10m"
    ...    default="10m"
    ${QUEUE_WAIT_THRESHOLD}=    RW.Core.Import User Variable    QUEUE_WAIT_THRESHOLD
    ...    type=string
    ...    description=The time threshold for builds in queue, formats like '5m', '2h', '1d' or '5min', '2h', '1d'
    ...    pattern=\d+
    ...    example="10m"
    ...    default="10m"
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
    ${MAX_FAILED_TESTS}=    RW.Core.Import User Variable    MAX_FAILED_TESTS
    ...    type=string
    ...    description=The maximum number of failed tests to consider healthy
    ...    pattern=\d+
    ...    example="1"
    ...    default="0"
    ${MAX_QUEUED_BUILDS}=    RW.Core.Import User Variable    MAX_QUEUED_BUILDS
    ...    type=string
    ...    description=The maximum number of builds stuck in queue to consider healthy
    ...    pattern=\d+
    ...    example="1"
    ...    default="0"
    ${WAIT_THRESHOLD}=    RW.Core.Import User Variable    WAIT_THRESHOLD
    ...    type=string
    ...    description=The threshold for builds stuck in queue, formats like '5m', '2h', '1d' or '5min', '2h', '1d'
    ...    pattern=\d+
    ...    example="1m"
    ...    default="10m"
    Set Suite Variable    ${env}    {"JENKINS_URL":"${JENKINS_URL}"}
    Set Suite Variable    ${JENKINS_URL}    ${JENKINS_URL}
    Set Suite Variable    ${JENKINS_USERNAME}    ${JENKINS_USERNAME}
    Set Suite Variable    ${JENKINS_TOKEN}    ${JENKINS_TOKEN}
    Set Suite Variable    ${TIME_THRESHOLD}    ${TIME_THRESHOLD}
    Set Suite Variable    ${MAX_FAILED_BUILDS}    ${MAX_FAILED_BUILDS}
    Set Suite Variable    ${MAX_LONG_RUNNING_BUILDS}    ${MAX_LONG_RUNNING_BUILDS}
    Set Suite Variable    ${MAX_FAILED_TESTS}    ${MAX_FAILED_TESTS}
    Set Suite Variable    ${MAX_QUEUED_BUILDS}    ${MAX_QUEUED_BUILDS}