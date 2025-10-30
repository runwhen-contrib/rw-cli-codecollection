*** Settings ***
Documentation       Measures the number of exception stacktraces present in an application's logs over a time period.
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes Application Monitor
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.K8sApplications
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Measure Application Exceptions in `${NAMESPACE}`
    [Documentation]    Examines recent logs for exceptions, providing a count of them.
    [Tags]    resource    application    workload    logs    state    exceptions    errors
    ${cmd}=    Set Variable
    ...    ${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} logs -l ${LABELS} --tail=${MAX_LOG_LINES} --limit-bytes=256000 --since=${RW_LOOKBACK_WINDOW} --container=${CONTAINER_NAME}
    IF    $EXCLUDE_PATTERN != ""
        ${cmd}=    Set Variable
        ...    ${cmd} | grep -Eiv "${EXCLUDE_PATTERN}" || true
    END

    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${cmd}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${parsed_exceptions}=    RW.K8sApplications.Parse Stacktraces    ${logs.stdout}
    ${count}=    Evaluate    len($parsed_exceptions)
    RW.Core.Push Metric    ${count}    sub_name=app_troubleshoot
    RW.Core.Push Metric    ${count}


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
    ${LABELS}=    RW.Core.Import User Variable    LABELS
    ...    type=string
    ...    description=The Kubernetes labels used to select the resource for logs.
    ...    pattern=\w*
    ${RW_LOOKBACK_WINDOW}=    RW.Core.Import Platform Variable    RW_LOOKBACK_WINDOW
    ${RW_LOOKBACK_WINDOW}=    RW.Core.Normalize Lookback Window     ${RW_LOOKBACK_WINDOW}     2     
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
    Set Suite Variable    ${LABELS}    ${LABELS}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${RW_LOOKBACK_WINDOW}    ${RW_LOOKBACK_WINDOW}
    Set Suite Variable    ${EXCLUDE_PATTERN}    ${EXCLUDE_PATTERN}
    Set Suite Variable    ${CONTAINER_NAME}    ${CONTAINER_NAME}
    Set Suite Variable    ${MAX_LOG_LINES}    ${MAX_LOG_LINES}
    Set Suite Variable
    ...    ${env}
    ...    {"LABELS":"${LABELS}", "KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}"}
