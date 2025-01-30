*** Settings ***
Documentation       Check For Jenkins health, failed builds, tests and long running builds
Metadata            Author    saurabh3460
Metadata            Display Name    Jenkins Health
Metadata            Supports    Jenkins

Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             String
Library             util.py
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

List Recent Faild Tests
    [Documentation]    List Recent Faild Tests
    [Tags]    Jenkins    Tests
    ${failed_tests}=    Get Failed Tests

    IF    len(${failed_tests}) > 0
        FOR    ${test_suite}    IN    @{failed_tests}
            ${pipeline_details}=    Set Variable    ${test_suite['pipeline_details']}
            ${test_results}=    Set Variable    ${test_suite['test_results']}
            
            ${pipeline_name}=    Set Variable    ${pipeline_details['pipeline_name']}
            ${build_number}=    Set Variable    ${pipeline_details['build_number']}
            
            ${json_str}=    Evaluate    json.dumps(${test_results})    json
            ${formatted_results}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '["FailedTests", "Duration", "StdErr", "StdOut"] as $headers | $headers, (.[] | [.name, .duration, .stderr, .stdout]) | @tsv' | column -t -s $'\t'
            RW.Core.Add Pre To Report    Pipeline Name: ${pipeline_name} Build No.${build_number}:\n=======================================\n${formatted_results.stdout}
            
            FOR    ${test}    IN    @{test_results}
                ${class_name}=    Set Variable    ${test['className']}
                ${test_name}=    Set Variable    ${test['name']}
                ${error_details}=    Set Variable    ${test['errorDetails']}
                ${stack_trace}=    Set Variable    ${test['errorStackTrace']}
                
                ${pretty_test}=    Evaluate    pprint.pformat(${test})    modules=pprint
                RW.Core.Add Issue
                ...    severity=3
                ...    expected=The test '${test_name}' in pipeline '${pipeline_name}' build number '${build_number}' should execute successfully
                ...    actual=Test execution failed with the following error:\n${error_details}
                ...    title=Test ${test_name} failed in pipeline ${pipeline_name} build number ${build_number}
                ...    details=Class: ${class_name} | Test: ${test_name}\nStack Trace:\n${stack_trace}\nComplete Test Information:\n${pretty_test}
                ...    reproduce_hint=Navigate to Jenkins build ${pipeline_name} #${build_number}
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

List Queued Builds
    [Documentation]    Check for builds stuck in queue beyond threshold
    [Tags]    Jenkins    Queue    Builds
    
    ${queued_builds}=    GET QUEUED BUILDS    wait_threshold=${QUEUE_WAIT_THRESHOLD}

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
                
                # Set severity based on conditions
                ${severity}=    Set Variable    1 if ${stuck} else (2 if ${blocked} else 3)
                
                # Create issue title based on status
                ${title}=    Set Variable If    ${stuck}    Build Stuck in Queue
                ...    ${blocked}    Build Blocked in Queue
                ...    Build Waiting in Queue
                
                # Add specific next steps based on status
                ${next_steps}=    Set Variable If    ${stuck}
                ...    - Check Jenkins executor status\n- Review system resources\n- Check for deadlocks\n- Consider restarting Jenkins if needed
                ...    ${blocked}
                ...    - Check if blocking job can be cancelled\n- Review job dependencies\n- Consider increasing executors if bottlenecked
                ...    - Monitor queue length trend\n- Consider adding more build agents\n- Review job priorities

                RW.Core.Add Issue
                ...    severity=3
                ...    expected=Builds should not be queued for extended periods
                ...    actual=Build has been waiting for ${wait_time}
                ...    title=${title}: ${job_name}
                ...    details=${build}
                ...    reproduce_hint=Check Jenkins queue at ${url}
                ...    next_steps=${next_steps}
            END
        END
        
    EXCEPT    AS    ${error}
        RW.Core.Add Pre To Report    Error fetching queued builds: ${error}
    END


Analyze Build Logs
    [Documentation]    Analyze build logs for common error patterns and similarities
    [Tags]    Jenkins    Logs    Analysis
    
    ${rsp}=    BUILD LOGS ANALYTICS

    TRY
        ${analysis_results}=    Evaluate    json.loads('''${rsp.stdout}''')    json
        
        FOR    ${result}    IN    @{analysis_results}
            ${job_name}=    Set Variable    ${result['job_name']}
            ${builds_analyzed}=    Set Variable    ${result['builds_analyzed']}
            ${similarity_score}=    Set Variable    ${result['similarity_score']}
            
            RW.Core.Add Pre To Report    Job: ${job_name}\nBuilds Analyzed: ${builds_analyzed}\nLog Similarity Score: ${similarity_score}%\n
            
            FOR    ${pattern}    IN    @{result['common_error_patterns']}
                ${occurrences}=    Set Variable    ${pattern['occurrences']}
                ${error_pattern}=    Set Variable    ${pattern['pattern']}
                
                RW.Core.Add Issue
                ...    severity=2
                ...    expected=Build logs should not contain recurring error patterns
                ...    actual=Found error pattern occurring ${occurrences} times across builds
                ...    title=Recurring Error Pattern in ${job_name}
                ...    details=Error Pattern:\n${error_pattern}\n\nOccurrences: ${occurrences}\nSimilar Lines:\n${pattern['similar_lines']}
                ...    reproduce_hint=Review build logs for job ${job_name}
                ...    next_steps=- Investigate root cause of recurring error pattern\n- Check if this is a systemic issue\n- Review job configuration
            END
        END
        
        IF    ${analysis_results} == []
            RW.Core.Add Pre To Report    No failed builds found for analysis
        END
        
    EXCEPT    AS    ${error}
        Log    ${error}
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
    ...    default="30m"
    ${QUEUE_WAIT_THRESHOLD}=    RW.Core.Import User Variable    QUEUE_WAIT_THRESHOLD
    ...    type=string
    ...    description=The time threshold for builds in queue, formats like '5m', '2h', '1d' or '5min', '2h', '1d'
    ...    pattern=\d+
    ...    example="1m"
    ...    default="10m"
    Set Suite Variable    ${env}    {"JENKINS_URL":"${JENKINS_URL}"}
    Set Suite Variable    ${TIME_THRESHOLD}    ${TIME_THRESHOLD}
    Set Suite Variable    ${JENKINS_URL}    ${JENKINS_URL}
    Set Suite Variable    ${JENKINS_USERNAME}    ${JENKINS_USERNAME}
    Set Suite Variable    ${JENKINS_TOKEN}    ${JENKINS_TOKEN}
    Set Suite Variable    ${QUEUE_WAIT_THRESHOLD}    ${QUEUE_WAIT_THRESHOLD}