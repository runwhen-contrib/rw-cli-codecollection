*** Settings ***
Documentation       List Jenkins health, failed builds, tests and long running builds
Metadata            Author    saurabh3460
Metadata            Display Name    Jenkins Health
Metadata            Supports    Jenkins

Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             String
Library             Jenkins
Suite Setup         Suite Initialization

*** Tasks ***
List Failed Build Logs in Jenkins
    [Documentation]    Fetches logs from failed Jenkins builds using the Jenkins API
    [Tags]    Jenkins    Logs    Builds
    ${rsp}=    RW.CLI.Run Bash File
    ...    bash_file=failed_build_logs.sh
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
            ${build_number}=    Set Variable    ${job['build_number']}
            ${json_str}=    Evaluate    json.dumps(${job})    json
            ${formatted_results}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '["Job Name", "Build #", "Result", "URL"] as $headers | $headers, (. | [.job_name, .build_number, .result, .url]) | @tsv' | column -t -s $'\t'
            RW.Core.Add Pre To Report    Failed Builds:\n=======================================\n${formatted_results.stdout}

            ${pretty_item}=    Evaluate    pprint.pformat(${job})    modules=pprint
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Jenkins job `${job_name}` should complete successfully
            ...    actual=Jenkins job `${job_name}` build #`${build_number}` failed
            ...    title=Jenkins Build Failure: `${job_name}` (Build #`${build_number}`)
            ...    reproduce_hint=Navigate to Jenkins build `${job_name}` #`${build_number}`
            ...    details=${pretty_item}
            ...    next_steps=Review Failed build logs for Jenkins job `${job_name}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No failed builds found"
    END

List Long Running Builds in Jenkins
    [Documentation]    Identifies Jenkins builds that have been running longer than a specified threshold
    [Tags]    Jenkins    Builds
    ${rsp}=    RW.CLI.Run Bash File
    ...    bash_file=long_running_builds.sh
    ...    cmd_override=./long_running_builds.sh ${LONG_RUNNING_BUILD_MAX_WAIT_TIME}
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
        ...    cmd=echo '${json_str}' | jq -r '["Job Name", "Build #", "Duration", "URL"] as $headers | $headers, (.[] | [.job_name, .build_number, .duration, .url]) | @tsv' | column -t -s $'\t'
        RW.Core.Add Pre To Report    Long Running Jobs:\n=======================================\n${formatted_results.stdout}
        
        FOR    ${job}    IN    @{long_running_jobs}
            ${job_name}=    Set Variable    ${job['job_name']}
            ${duration}=    Set Variable    ${job['duration']}
            ${build_number}=    Set Variable    ${job['build_number']}
            ${url}=    Set Variable    ${job['url']}

            ${pretty_item}=    Evaluate    pprint.pformat(${job})    modules=pprint
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Jenkins job `${job_name}` (Build #`${build_number}`) should complete within ${LONG_RUNNING_BUILD_MAX_WAIT_TIME}
            ...    actual=Jenkins job `${job_name}` (Build #`${build_number}`) has been running for ${duration} (exceeds threshold)
            ...    title=Long Running Build: `${job_name}` (Build #`${build_number}`) - ${duration}
            ...    reproduce_hint=Navigate to Jenkins build `${job_name}` #`${build_number}`
            ...    details=${pretty_item}
            ...    next_steps=Investigate build logs of job `${job_name}`\nCheck resource utilization on build node
        END
    ELSE
        RW.Core.Add Pre To Report    "No long running builds found"
    END

List Recent Failed Tests in Jenkins
    [Documentation]    List Recent Failed Tests in Jenkins
    [Tags]    Jenkins    Tests
    ${failed_tests}=    Jenkins.Get Failed Tests
    ...    jenkins_url=${JENKINS_URL}
    ...    jenkins_username=${JENKINS_USERNAME}
    ...    jenkins_token=${JENKINS_TOKEN}

    IF    len(${failed_tests}) > 0
        FOR    ${test_suite}    IN    @{failed_tests}
            ${pipeline_details}=    Set Variable    ${test_suite['pipeline_details']}
            ${test_results}=    Set Variable    ${test_suite['test_results']}
            ${pipeline_url}=    Set Variable    ${pipeline_details['pipeline_url']}
            ${pipeline_name}=    Set Variable    ${pipeline_details['pipeline_name']}
            ${build_number}=    Set Variable    ${pipeline_details['build_number']}
            
            ${json_str}=    Evaluate    json.dumps(${test_results})    json
            ${formatted_results}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '["FailedTests", "Duration", "StdErr", "StdOut", "Status"] as $headers | $headers, (.[] | [.name, .duration, .stderr, .stdout, .status]) | @tsv' | column -t -s $'\t'
            RW.Core.Add Pre To Report    Pipeline Name: ${pipeline_name} Build No.${build_number}:\n=======================================\n${formatted_results.stdout}
            
            FOR    ${test}    IN    @{test_results}
                ${class_name}=    Set Variable    ${test['className']}
                ${test_name}=    Set Variable    ${test['name']}
                ${error_details}=    Set Variable    ${test['errorDetails']}
                ${stack_trace}=    Set Variable    ${test['errorStackTrace']}
                
                ${pretty_test}=    Evaluate    pprint.pformat(${test})    modules=pprint
                RW.Core.Add Issue
                ...    severity=3
                ...    expected=Test `${test_name}` in pipeline `${pipeline_name}` (Build #`${build_number}`) should pass successfully
                ...    actual=Test '${test_name}' failed with error:\n${error_details}
                ...    title=Test Failure: `${test_name}` in ${pipeline_name} (Build #`${build_number}`)
                ...    details=${pretty_test}
                ...    reproduce_hint=Navigate to Jenkins build `${pipeline_url}lastCompletedBuild/testReport/`
                ...    next_steps=Review the error message and stack trace
            END
        END
    ELSE
        RW.Core.Add Pre To Report    "No failed tests found"
    END

Check Jenkins Health
    [Documentation]    Check if Jenkins instance is reachable and responding
    [Tags]    Jenkins    Health
    # TODO: Capture more exceptions here 
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=curl -s -u "$${JENKINS_USERNAME.key}:$${JENKINS_TOKEN.key}" "${JENKINS_URL}/api/json"
    ...    env=${env}
    ...    secret__jenkins_token=${JENKINS_TOKEN}
    ...    secret__jenkins_username=${JENKINS_USERNAME}
    TRY
        ${data}=    Evaluate    json.loads('''${rsp.stdout}''')    json
        RW.Core.Add Pre To Report    Jenkins instance is up and responding
    EXCEPT
        RW.Core.Add Issue
        ...    severity=1
        ...    expected=Jenkins instance at ${JENKINS_URL}/api/json should be reachable and responding
        ...    actual=Unable to connect to Jenkins instance or received invalid response
        ...    title=Jenkins instance is not reachable
        ...    details=Failed to connect to Jenkins instance at ${JENKINS_URL}/api/json response: ${rsp.stdout}
        ...    reproduce_hint=Try accessing ${JENKINS_URL}/api/json in a web browser
        ...    next_steps=- Check if Jenkins service is running\n- Verify network connectivity\n- Validate Jenkins URL\n- Check Jenkins logs for errors
    END

List Long Queued Builds in Jenkins
    [Documentation]    Check for builds stuck in queue beyond threshold
    [Tags]    Jenkins    Queue    Builds
    
    ${queued_builds}=    Jenkins.Get Queued Builds    
    ...    jenkins_url=${JENKINS_URL}
    ...    jenkins_username=${JENKINS_USERNAME}
    ...    jenkins_token=${JENKINS_TOKEN}
    ...    wait_threshold=${QUEUED_BUILD_MAX_WAIT_TIME}

    TRY 
        IF    ${queued_builds} == []
            RW.Core.Add Pre To Report    No builds currently queued beyond threshold
        ELSE
            ${json_str}=    Evaluate    json.dumps(${queued_builds})    json
            ${formatted_results}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '["Job Name", "Wait Time", "Why", "Stuck", "Blocked", "URL"] as $headers | $headers, (.[] | [.job_name, .wait_time, .why, .stuck, .blocked, .url]) | @tsv' | column -t -s $'\t'
            RW.Core.Add Pre To Report    Builds Currently Queued:\n=======================================\n${formatted_results.stdout}
            
            FOR    ${build}    IN    @{queued_builds}
                ${url}=    Set Variable    ${build['url']}
                ${job_name}=    Set Variable    ${build['job_name']}
                ${wait_time}=    Set Variable    ${build['wait_time']}
                ${why}=    Set Variable    ${build['why']}
                ${stuck}=    Set Variable    ${build['stuck']}
                ${blocked}=    Set Variable    ${build['blocked']}
                                
                # Add specific next steps based on status
                ${next_steps}=    Set Variable If    ${stuck}
                ...    - Check Jenkins executor status\n- Review system resources\n- Consider restarting Jenkins if needed
                ...    ${blocked}
                ...    Consider increasing executors if bottlenecked
                ...    Consider adding more build agents

                RW.Core.Add Issue
                ...    severity=4
                ...    expected=Builds should not be queued for more than ${QUEUED_BUILD_MAX_WAIT_TIME}
                ...    actual=Build '${job_name}' has been queued for ${wait_time} (exceeds threshold)
                ...    title=Long Queued Build: ${job_name} (${wait_time})
                ...    details=${build}
                ...    reproduce_hint=Access Jenkins at ${JENKINS_URL}
                ...    next_steps=${next_steps}
            END
        END
        
    EXCEPT
        RW.Core.Add Pre To Report    No queued builds found
    END


List Jenkins Executor Utilization
    [Documentation]    Check Jenkins executor utilization across nodes
    [Tags]    Jenkins    Executors    Utilization
    
    ${executor_utilization}=    Jenkins.Get Executor Utilization
    ...    jenkins_url=${JENKINS_URL}
    ...    jenkins_username=${JENKINS_USERNAME}
    ...    jenkins_token=${JENKINS_TOKEN}

    TRY 
        IF    ${executor_utilization} == []
            RW.Core.Add Pre To Report    No executor utilization data found
        ELSE
            ${json_str}=    Evaluate    json.dumps(${executor_utilization})    json
            ${formatted_results}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '["Node Name", "Busy Executors", "Total Executors", "Utilization %"] as $headers | $headers, (.[] | [.node_name, .busy_executors, .total_executors, .utilization_percentage]) | @tsv' | column -t -s $'\t'
            RW.Core.Add Pre To Report    Executor Utilization:\n=======================================\n${formatted_results.stdout}
            
            FOR    ${executor}    IN    @{executor_utilization}
                ${node_name}=    Set Variable    ${executor['node_name']}
                ${utilization}=    Set Variable    ${executor['utilization_percentage']}
                ${busy_executors}=    Set Variable    ${executor['busy_executors']}
                ${total_executors}=    Set Variable    ${executor['total_executors']}
                
                IF    ${utilization} > float(${MAX_EXECUTOR_UTILIZATION})
                    RW.Core.Add Issue
                    ...    severity=3
                    ...    expected=Executor utilization should be below ${MAX_EXECUTOR_UTILIZATION}%
                    ...    actual=Node '${node_name}' has ${utilization}% utilization (${busy_executors}/${total_executors} executors busy)
                    ...    title=Jenkins High Executor Utilization: ${node_name} (${utilization}%)
                    ...    details=${executor}
                    ...    reproduce_hint=Check executor status at ${JENKINS_URL}/computer/
                    ...    next_steps=- Consider adding more executors\n- Review job distribution\n- Check for stuck builds
                END
            END
        END
        
    EXCEPT
        RW.Core.Add Pre To Report    Failed to fetch executor utilization data
    END


Fetch Jenkins Logs and Add to Report
    [Documentation]    Fetches and displays Jenkins logs from the Atom feed
    [Tags]    Jenkins    Logs
    ${rsp}=    Jenkins.Parse Atom Feed
    ...    jenkins_url=${JENKINS_URL}
    ...    jenkins_username=${JENKINS_USERNAME}
    ...    jenkins_token=${JENKINS_TOKEN}
    RW.Core.Add Pre To Report    ${rsp}


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
    ${LONG_RUNNING_BUILD_MAX_WAIT_TIME}=    RW.Core.Import User Variable    LONG_RUNNING_BUILD_MAX_WAIT_TIME
    ...    type=string
    ...    description=The threshold for long running builds, formats like '5m', '2h', '1d' or '5min', '2h', '1d'
    ...    pattern=\d+
    ...    example="10m"
    ...    default="10m"
    ${QUEUED_BUILD_MAX_WAIT_TIME}=    RW.Core.Import User Variable    QUEUED_BUILD_MAX_WAIT_TIME
    ...    type=string
    ...    description=The time threshold for builds in queue, formats like '5m', '2h', '1d' or '5min', '2h', '1d'
    ...    pattern=\d+
    ...    example="10m"
    ...    default="10m"
    ${MAX_EXECUTOR_UTILIZATION}=    RW.Core.Import User Variable    MAX_EXECUTOR_UTILIZATION
    ...    type=string
    ...    description=The maximum percentage of executor utilization to consider healthy
    ...    pattern=\d+
    ...    example="80"
    ...    default="80"
    Set Suite Variable    ${LONG_RUNNING_BUILD_MAX_WAIT_TIME}    ${LONG_RUNNING_BUILD_MAX_WAIT_TIME}
    Set Suite Variable    ${JENKINS_URL}    ${JENKINS_URL}
    Set Suite Variable    ${JENKINS_USERNAME}    ${JENKINS_USERNAME}
    Set Suite Variable    ${JENKINS_TOKEN}    ${JENKINS_TOKEN}
    Set Suite Variable    ${QUEUED_BUILD_MAX_WAIT_TIME}    ${QUEUED_BUILD_MAX_WAIT_TIME}
    Set Suite Variable    ${MAX_EXECUTOR_UTILIZATION}    ${MAX_EXECUTOR_UTILIZATION}
    Set Suite Variable    ${env}    {"JENKINS_URL":"${JENKINS_URL}"}
    #Set Suite Variable    ${env}    {"JENKINS_URL":"${JENKINS_URL}", "JENKINS_USERNAME":"${JENKINS_USERNAME.key}", "JENKINS_TOKEN":"${JENKINS_TOKEN.key}"}
