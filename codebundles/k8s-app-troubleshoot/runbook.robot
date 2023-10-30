*** Settings ***
Documentation       Triages issues related to a deployment and its replicas.
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes Application Troubleshoot
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.NextSteps
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Get Resource Logs
    [Documentation]    Collects the last approximately 200 lines of logs from the resource before restarting it.
    [Tags]    resource    application    workload    logs    state
    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} logs deployment,statefulset -l ${LABELS} --tail=200 --limit-bytes=256000
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    Resource Logs:\n\n${logs.stdout}
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


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${kubectl}=    RW.Core.Import Service    kubectl
    ...    description=The location service used to interpret shell commands.
    ...    default=kubectl-service.shared
    ...    example=kubectl-service.shared
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
    ${LABELS}=    RW.Core.Import User Variable    LABELS
    ...    type=string
    ...    description=The Kubernetes labels used to select the resource for logs.
    ...    pattern=\w*
    ${NUM_OF_COMMITS}=    RW.Core.Import User Variable
    ...    NUM_OF_COMMITS
    ...    type=string
    ...    description=The number of commits to look through when troubleshooting. Adjust this based on your team's git usage and commit frequency.
    ...    pattern=\w*
    ...    example=3
    ...    default=3
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${REPO_URI}    ${REPO_URI}
    Set Suite Variable    ${LABELS}    ${LABELS}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable
    ...    ${env}
    ...    {"NUM_OF_COMMITS":"${NUM_OF_COMMITS}", "REPO_URI":"${REPO_URI}", "LABELS":"${LABELS}", "KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}"}
