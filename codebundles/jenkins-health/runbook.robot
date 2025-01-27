*** Settings ***
Documentation       This taskset collects information about Jenkins health and failed builds to help troubleshoot potential issues.
Metadata            Author    saurabh3460
Metadata            Display Name    Jenkins Healthcheck
Metadata            Supports    Jenkins

Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization

*** Tasks ***
List Failed Jenkins Builds
    [Documentation]    Fetches logs from failed Jenkins builds using the Jenkins API
    [Tags]    Jenkins    Logs    Failures    API    Builds
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
    IF    len(@{jobs}) > 0
        FOR    ${job}    IN    @{jobs}
            ${job_name}=    Set Variable    ${job['job_name']}
            ${build_number}=    Set Variable    ${job['buildNumber']}
            ${logs}=    Set Variable    ${job['logs']}
            
            RW.Core.Add Pre To Report    ${job}

            ${pretty_item}=    Evaluate    pprint.pformat(${job})    modules=pprint
            RW.Core.Add Issue        
            ...    severity=3
            ...    expected=Jenkins job `${job_name}` should have a successful build
            ...    actual=Jenkins job `${job_name}` has a failed build
            ...    title=Jenkins job `${job_name}` has a failed build
            ...    reproduce_hint=${rsp.cmd}
            ...    details=${pretty_item}
            ...    next_steps=Review the Jenkins job `${job_name}` build number `${build_number}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No failed builds found"
    END

List Long Running Builds
    [Documentation]    Identifies Jenkins builds that have been running longer than a specified threshold
    [Tags]    Jenkins    Builds    Monitoring
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

    ${long_running_jobs}=    Set Variable    ${data.get('long_running_jobs', [])}

    IF    len(${long_running_jobs}) > 0
        ${json_str}=    Evaluate    json.dumps(${long_running_jobs})    json
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=echo '${json_str}' | jq -r '["Job Name", "Build #", "Duration", "URL"] as $headers | $headers, (.[] | [.name, .build_number, .duration, .url]) | @tsv' | column -t -s $'\t'
        RW.Core.Add Pre To Report    Long Running Jobs:\n${formatted_results.stdout}
        
        FOR    ${job}    IN    @{long_running_jobs}
            ${job_name}=    Set Variable    ${job['name']}
            ${duration}=    Set Variable    ${job['duration']}
            ${build_number}=    Set Variable    ${job['build_number']}
            ${url}=    Set Variable    ${job['url']}

            ${pretty_item}=    Evaluate    pprint.pformat(${job})    modules=pprint
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Jenkins job `${job_name}` should complete within ${TIME_THRESHOLD}
            ...    actual=Jenkins job `${job_name}` has been running for ${duration}
            ...    title=Jenkins job build `${job_name}` `${build_number}` has been running for ${duration}
            ...    reproduce_hint=${rsp.cmd}
            ...    details=${pretty_item}
            ...    next_steps=Review the Jenkins job `${job_name}` build number `${build_number}` at ${url}
        END
    ELSE
        RW.Core.Add Pre To Report    "No long running builds found"
    END

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
    Set Suite Variable    ${env}    {"JENKINS_URL":"${JENKINS_URL}"}
    Set Suite Variable    ${TIME_THRESHOLD}    ${TIME_THRESHOLD}
    Set Suite Variable    ${JENKINS_URL}    ${JENKINS_URL}
    Set Suite Variable    ${JENKINS_USERNAME}    ${JENKINS_USERNAME}
    Set Suite Variable    ${JENKINS_TOKEN}    ${JENKINS_TOKEN}
    