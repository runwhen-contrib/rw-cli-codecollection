*** Settings ***
Documentation       Performs application-level troubleshooting by inspecting the logs of a workload for parsable exceptions,
...                 and attempts to determine next steps.
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes Application Troubleshoot
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.K8sApplications
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Get Workload Logs
    [Documentation]    Collects the last approximately 300 lines of logs from the workload before restarting it.
    [Tags]    resource    application    workload    logs    state    ${container_name}
    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} logs -l ${LABELS} --tail=${MAX_LOG_LINES} --limit-bytes=256000 --since=${LOGS_SINCE} --container=${CONTAINER_NAME}
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    Workload Logs:\n\n${logs.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Scan For Misconfigured Environment
    [Documentation]    Compares codebase to configured infra environment variables and attempts to report missing environment variables in the app
    [Tags]    environment    variables    env    infra    ${container_name}
    ${script_run}=    RW.CLI.Run Bash File
    ...    bash_file=env_check.sh
    ...    include_in_history=False
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Stdout:\n\n${script_run.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Troubleshoot Application Logs
    [Documentation]    Performs an inspection on container logs for exceptions/stacktraces, parsing them and attempts to find relevant source code information
    [Tags]    application    debug    app    errors    troubleshoot    workload    api    logs    ${container_name}
    ${cmd}=    Set Variable
    ...    ${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} logs -l ${LABELS} --tail=${MAX_LOG_LINES} --limit-bytes=256000 --since=${LOGS_SINCE} --container=${CONTAINER_NAME}
    IF    $EXCLUDE_PATTERN != ""
        ${cmd}=    Set Variable
        ...    ${cmd} | grep -Eiv "${EXCLUDE_PATTERN}" || true
    END
    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${cmd}
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${printenv}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} exec $(${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} get all -l ${LABELS} -oname | grep -iE "deploy|stateful" | head -n 1) --container=${CONTAINER_NAME} -- printenv
    ...    render_in_commandlist=true
    ...    include_in_history=False
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${proc_list}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} exec $(${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} get all -l ${LABELS} -oname | grep -iE "deploy|stateful" | head -n 1) --container=${CONTAINER_NAME} -- ps -eo command --no-header | grep -v "ps -eo"
    ...    render_in_commandlist=true
    ...    include_in_history=False
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}

    # ${test_data}=    RW.K8sApplications.Get Test Data
    ${proc_list}=    RW.K8sApplications.Format Process List    ${proc_list.stdout}
    ${serialized_env}=    RW.K8sApplications.Serialize env    ${printenv.stdout}
    ${parsed_exceptions}=    RW.K8sApplications.Parse Exceptions    ${logs.stdout}
    # ${parsed_exceptions}=    RW.K8sApplications.Parse Exceptions    ${test_data}
    ${app_repo}=    RW.K8sApplications.Clone Repo    ${REPO_URI}    ${REPO_AUTH_TOKEN}    ${NUM_OF_COMMITS}
    ${repos}=    Create List    ${app_repo}
    ${ts_results}=    RW.K8sApplications.Troubleshoot Application
    ...    repos=${repos}
    ...    exceptions=${parsed_exceptions}
    ...    env=${serialized_env}
    ...    process_list=${proc_list}
    ${history}=    RW.CLI.Pop Shell History
    ${full_report}=    Evaluate    $ts_results.get("report")
    ${found_exceptions}=    Evaluate    $ts_results.get("found_exceptions")
    ${full_report}=    Set Variable
    ...    ${full_report}\nHere's the command used to collect the exception data:\n```${history}```
    RW.Core.Add Pre To Report    ${full_report}

    ${issue_link}=    Set Variable    None
    IF    "${CREATE_ISSUES}" == "YES" and (len($parsed_exceptions)) > 0
        ${issue_link}=    RW.K8sApplications.Create Github Issue    ${repos[0]}    ${full_report}
        RW.Core.Add Pre To Report    \n${issue_link}
    END
    ${nextsteps}=    Evaluate
    ...    "${issue_link}" if ("http" in """${issue_link}""") else "View the summary in details for possible links to the source code related to the exceptions found in the ${CONTAINER_NAME} application."
    IF    (len($parsed_exceptions)) > 0
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=No exceptions were found in the parsed logs of workload ${CONTAINER_NAME}
        ...    actual=Found exceptions in the workload logs of ${CONTAINER_NAME}
        ...    reproduce_hint=Run:\n${cmd}\n view logs results for exceptions.
        ...    title=Found exception in ${CONTAINER_NAME} logs
        ...    details=${full_report}
        ...    next_steps=${nextsteps}
    END

# TODO: implement tasks:
# Troubleshoot Application Endpoints
# Check Database Migrations


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=The name of the Kubernetes namespace to scope actions and searching to.
    ...    pattern=\w*
    ...    example=my-namespace
    ...    default=sock-shop
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=sandbox-cluster-1
    ...    default=sandbox-cluster-1
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    ${REPO_URI}=    RW.Core.Import User Variable    REPO_URI
    ...    type=string
    ...    description=Repo URI for the source code to inspect.
    ...    pattern=\w*
    ...    example=https://github.com/runwhen-contrib/runwhen-local
    ...    default=https://github.com/runwhen-contrib/runwhen-local
    ${REPO_AUTH_TOKEN}=    RW.Core.Import Secret
    ...    REPO_AUTH_TOKEN
    ...    type=string
    ...    description=The oauth token to be used for authenticating to the repo during cloning.
    ...    pattern=\w*
    ${LABELS}=    RW.Core.Import User Variable    LABELS
    ...    type=string
    ...    description=The Kubernetes labels used to select the resource for logs.
    ...    pattern=\w*
    ${NUM_OF_COMMITS}=    RW.Core.Import User Variable
    ...    NUM_OF_COMMITS
    ...    type=string
    ...    description=The number of commits to look through when troubleshooting. Adjust this based on your team's git usage and commit frequency.
    ...    pattern=\w*
    ...    example=50
    ...    default=50
    ${CREATE_ISSUES}=    RW.Core.Import User Variable    CREATE_ISSUES
    ...    type=string
    ...    description=Whether or not the taskset should create github issues when it finds problems.
    ...    enum=[YES,NO]
    ...    example=YES
    ...    default=YES
    ${LOGS_SINCE}=    RW.Core.Import User Variable
    ...    LOGS_SINCE
    ...    type=string
    ...    description=How far back to fetch logs from containers in Kubernetes. Making this too recent and running the codebundle often could cause adverse performance.
    ...    pattern=\w*
    ...    example=15m
    ...    default=15m
    ${EXCLUDE_PATTERN}=    RW.Core.Import User Variable
    ...    EXCLUDE_PATTERN
    ...    type=string
    ...    description=Grep pattern to use to exclude exceptions that don't indicate a critical issue.
    ...    pattern=\w*
    ...    example=FalseError|SecondErrorToSkip
    ...    default=FalseError|SecondErrorToSkip
    ${CONTAINER_NAME}=    RW.Core.Import User Variable
    ...    CONTAINER_NAME
    ...    type=string
    ...    description=The name of the container within the selected pod that represents the application to troubleshoot.
    ...    pattern=\w*
    ...    example=myapp
    ${MAX_LOG_LINES}=    RW.Core.Import User Variable
    ...    MAX_LOG_LINES
    ...    type=string
    ...    description=The max number of log lines to request from Kubernetes workloads to be parsed. Setting this too high can adversely effect performance.
    ...    pattern=\w*
    ...    example=300
    ...    default=300
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${REPO_URI}    ${REPO_URI}
    Set Suite Variable    ${LABELS}    ${LABELS}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${REPO_AUTH_TOKEN}    ${REPO_AUTH_TOKEN}
    Set Suite Variable    ${CREATE_ISSUES}    ${CREATE_ISSUES}
    Set Suite Variable    ${LOGS_SINCE}    ${LOGS_SINCE}
    Set Suite Variable    ${EXCLUDE_PATTERN}    ${EXCLUDE_PATTERN}
    Set Suite Variable    ${CONTAINER_NAME}    ${CONTAINER_NAME}
    Set Suite Variable    ${NUM_OF_COMMITS}    ${NUM_OF_COMMITS}
    Set Suite Variable    ${MAX_LOG_LINES}    ${MAX_LOG_LINES}
    Set Suite Variable
    ...    ${env}
    ...    {"NUM_OF_COMMITS":"${NUM_OF_COMMITS}", "REPO_URI":"${REPO_URI}", "LABELS":"${LABELS}", "KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}"}
