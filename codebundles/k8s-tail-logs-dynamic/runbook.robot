*** Settings ***
Documentation       Performs application-level troubleshooting by inspecting the logs of a workload for parsable exceptions,
...                 and attempts to determine next steps.
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes Tail Application Logs
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift,GoLang,Json,Python,CSharp,Django,Node,Java,FastAPI

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.K8sApplications
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Get `${CONTAINER_NAME}` Application Logs
    [Documentation]    Collects the last approximately 300 lines of logs from the workload
    [Tags]    resource    application    workload    logs    state    ${container_name}    ${workload_name}
    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} logs -l ${LABELS} --tail=${MAX_LOG_LINES} --max-log-requests=10 --limit-bytes=${MAX_LOG_BYTES} --since=${LOGS_SINCE} --container=${CONTAINER_NAME}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    Workload Logs:\n\n${logs.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Tail `${CONTAINER_NAME}` Application Logs For Stacktraces
    [Documentation]    Performs an inspection on container logs for exceptions/stacktraces, parsing them and attempts to find relevant source code information
    [Tags]
    ...    application
    ...    debug
    ...    app
    ...    errors
    ...    troubleshoot
    ...    workload
    ...    api
    ...    logs
    ...    ${container_name}
    ...    ${workload_name}
    ${cmd}=    Set Variable
    ...    ${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} logs -l ${LABELS} --tail=${MAX_LOG_LINES} --max-log-requests=10 --limit-bytes=${MAX_LOG_BYTES} --since=${LOGS_SINCE} --container=${CONTAINER_NAME}
    IF    $EXCLUDE_PATTERN != ""
        ${cmd}=    Set Variable
        ...    ${cmd} | grep -Ev "${EXCLUDE_PATTERN}" || true
    END
    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${cmd}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${parsed_stacktraces}=    RW.K8sApplications.Dynamic Parse Stacktraces    ${logs.stdout}
    ...    parser_name=${STACKTRACE_PARSER}
    ...    parse_mode=${INPUT_MODE}
    ...    show_debug=True
    ${report_data}=    RW.K8sApplications.Stacktrace Report Data   stacktraces=${parsed_stacktraces}
    ${report}=    Set Variable    ${report_data["report"]}
    ${history}=    RW.CLI.Pop Shell History
    IF    (len($parsed_stacktraces)) > 0
        ${mcst}=    Set Variable    ${report_data["most_common_stacktrace"]}
        ${first_file}=    Set Variable    ${mcst.get_first_file_line_nums_as_str()}
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=No stacktraces were found in the application logs of ${CONTAINER_NAME}
        ...    actual=Found stacktraces in the application logs of ${CONTAINER_NAME}
        ...    reproduce_hint=Run:\n${cmd}\n view logs results for stacktraces.
        ...    title=Stacktraces Found In Tailed Logs Of `${CONTAINER_NAME}`
        ...    details=Generated a report of the stacktraces found to be reviewed.
        ...    next_steps=Check this file ${first_file} for the most common stacktrace and review the full report for more details.
    END
    RW.Core.Add Pre To Report    ${report}
    RW.Core.Add Pre To Report    Commands Used: ${history}
#TODO: replicaset check
#TODO: rollout workload
#TODO: check if a service has a selector for this deployment


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
    ${LOGS_SINCE}=    RW.Core.Import User Variable
    ...    LOGS_SINCE
    ...    type=string
    ...    description=How far back to fetch logs from containers in Kubernetes. Making this too recent and running the codebundle often could cause adverse performance.
    ...    pattern=\w*
    ...    example=30m
    ...    default=30m
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
    ...    example=1500
    ...    default=1500
    ${LABELS}=    RW.Core.Import User Variable    LABELS
    ...    type=string
    ...    description=The Kubernetes labels used to select the resource for logs.
    ...    pattern=\w*
    ${STACKTRACE_PARSER}=    RW.Core.Import User Variable    STACKTRACE_PARSER
    ...    type=string
    ...    enum=[Dynamic,GoLang,GoLangJson,CSharp,Python,Django,DjangoJson]
    ...    description=What parser implementation to use when going through logs. Dynamic will use the first successful parser which is more computationally expensive.
    ...    default=Dynamic
    ...    example=Dynamic
    ${INPUT_MODE}=    RW.Core.Import User Variable    INPUT_MODE
    ...    type=string
    ...    enum=[SPLIT,MULTILINE]
    ...    description=Changes ingestion style of logs, typically split (1 log per line) works best.
    ...    default=SPLIT
    ...    example=SPLIT
    ${MAX_LOG_BYTES}=    RW.Core.Import User Variable
    ...    MAX_LOG_BYTES
    ...    type=string
    ...    description=The maximum number of bytes to constrain the log fetch with. Setting this too high can adversely effect performance.
    ...    pattern=\w*
    ...    example=2560000
    ...    default=2560000
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${LOGS_SINCE}    ${LOGS_SINCE}
    Set Suite Variable    ${EXCLUDE_PATTERN}    ${EXCLUDE_PATTERN}
    Set Suite Variable    ${LABELS}    ${LABELS}
    Set Suite Variable    ${CONTAINER_NAME}    ${CONTAINER_NAME}
    Set Suite Variable    ${MAX_LOG_LINES}    ${MAX_LOG_LINES}
    Set Suite Variable    ${STACKTRACE_PARSER}    ${STACKTRACE_PARSER}
    Set Suite Variable    ${INPUT_MODE}    ${INPUT_MODE}
    Set Suite Variable    ${MAX_LOG_BYTES}    ${MAX_LOG_BYTES}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}"}
