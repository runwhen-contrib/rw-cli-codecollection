*** Settings ***
Documentation       Triages issues related to a deployment and its replicas.
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes Application Troubleshoot
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.K8sApplications
Library             RW.platform
Library             RW.NextSteps
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Get Workload Logs
    [Documentation]    Collects the last approximately 300 lines of logs from the workload before restarting it.
    [Tags]    resource    application    workload    logs    state
    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} logs deployment,statefulset -l ${LABELS} --tail=300 --limit-bytes=256000 --all-containers --since=${LOGS_SINCE}
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    Workload Logs:\n\n${logs.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Scan For Misconfigured Environment
    [Documentation]    Compares codebase to configured infra environment variables and attempts to report missing environment variables in the app
    [Tags]    environment    variables    env    infra
    ${script_run}=    RW.CLI.Run Bash File
    ...    bash_file=env_check.sh
    ...    include_in_history=False
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Stdout:\n\n${script_run.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Troubleshoot Application Logs
    ${cmd}=    Set Variable
    ...    ${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} logs $(${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} get deployment,statefulset -l ${LABELS} -oname | head -n 1) --tail=100 --limit-bytes=256000 --since=${LOGS_SINCE} --container=${CONTAINER_NAME}
    IF    $EXCLUDE_PATTERN != ""
        ${cmd}=    Set Variable
        ...    ${cmd} | grep -EiV "${EXCLUDE_PATTERN}" || true
    END
    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${cmd}
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${printenv}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} exec $(${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} get all -l ${LABELS} -oname | grep -iE "deploy|stateful" | head -n 1) --container=${CONTAINER_NAME} -- printenv
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${proc_list}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} exec $(${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} get all -l ${LABELS} -oname | grep -iE "deploy|stateful" | head -n 1) --container=${CONTAINER_NAME} -- ps -eo command --no-header | grep -v "ps -eo"
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}

    ${proc_list}=    RW.K8sApplications.Format Process List    ${proc_list.stdout}
    ${serialized_env}=    RW.K8sApplications.Serialize env    ${printenv.stdout}
    ${parsed_exceptions}=    RW.K8sApplications.Parse Exceptions    ${logs.stdout}
    ${app_repo}=    RW.K8sApplications.Clone Repo    ${REPO_URI}    ${REPO_AUTH_TOKEN}
    ${repos}=    Create List    ${app_repo}
    ${ts_results}=    RW.K8sApplications.Troubleshoot Application
    ...    repos=${repos}
    ...    exceptions=${parsed_exceptions}
    ...    env=${serialized_env}
    ...    process_list=${proc_list}

Troubleshoot Application Endpoints
    log
    ...    get urls from env and souce code -> inspect namespace for URLs -> ping URLs -> wait, query logs for matching urls


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
    ...    example=10
    ...    default=10
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
    Set Suite Variable
    ...    ${env}
    ...    {"NUM_OF_COMMITS":"${NUM_OF_COMMITS}", "REPO_URI":"${REPO_URI}", "LABELS":"${LABELS}", "KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}"}
