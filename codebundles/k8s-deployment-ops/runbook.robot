*** Settings ***
Documentation       Perform oprational tasks for a Kubernetes deployment.
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes Deployment Triage
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.NextSteps
Library             RW.K8sHelper
Library             OperatingSystem
Library             String

Suite Setup         Suite Initialization


*** Tasks ***
Restart Deployment `${DEPLOYMENT_NAME}`
    [Documentation]    Perform a rollout restart on the deployment
    [Tags]
    ...    log
    ...    pod
    ...    restart
    ...    deployment
    ...    ${DEPLOYMENT_NAME}

    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} logs deployment/${DEPLOYMENT_NAME} --tail 50 -n ${NAMESPACE} --all-containers=true --max-log-requests=20 --context ${CONTEXT}
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    ----------\nPre restart log output:\n${logs.stdout}

    ${rollout}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} rollout restart deployment/${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT}; while true; do STATUS=$(${KUBERNETES_DISTRIBUTION_BINARY} rollout status deployment/${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} --timeout=180s); echo "$STATUS"; [[ "$STATUS" == *"successfully rolled out"* ]] && break; sleep 5; done
    ...    env=${env}
    ...    include_in_history=false
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    ----------\nRollout Output:\n${rollout.stdout}

    IF    $rollout.stderr != ""
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` should have restarted successfully
        ...    actual=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` did not restarted successfully
        ...    title=Deployment `${DEPLOYMENT_NAME}` in `${NAMESPACE}` did not rollout properly
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} generated the following output during restart attempt: \n${rollout.stderr}
        ...    next_steps=Escalate restart issue to service owner.
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}
*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${DEPLOYMENT_NAME}=    RW.Core.Import User Variable    DEPLOYMENT_NAME
    ...    type=string
    ...    description=Used to target the resource for queries and filtering events.
    ...    pattern=\w*
    ...    example=artifactory
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=The name of the Kubernetes namespace to scope actions and searching to.
    ...    pattern=\w*
    ...    example=my-namespace
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    ${HOME}=    RW.Core.Import User Variable    HOME
    ...    type=string
    ...    description=The home path of the runner
    ...    pattern=\w*
    ...    example=/home/runwhen
    ...    default=/home/runwhen 
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${DEPLOYMENT_NAME}    ${DEPLOYMENT_NAME}
    Set Suite Variable    ${HOME}    ${HOME}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}", "DEPLOYMENT_NAME": "${DEPLOYMENT_NAME}", "HOME":"${HOME}"}