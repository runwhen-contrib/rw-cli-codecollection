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
Restart Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Perform a rollout restart on the deployment
    [Tags]
    ...    log
    ...    pod
    ...    restart
    ...    deployment
    ...    ${DEPLOYMENT_NAME}

    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} logs deployment/${DEPLOYMENT_NAME} --tail 50 --all-containers=true --max-log-requests=20 -n ${NAMESPACE} --context ${CONTEXT}
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    ----------\nPre restart log output:\n${logs.stdout}

    ${rollout}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} rollout restart deployment/${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT}
    ...    env=${env}
    ...    include_in_history=false
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    ----------\nRestart Output:\n${rollout.stdout}

    IF    ($rollout.stderr) == ""
        ${rollout_status}=    RW.CLI.Run Cli
        ...    cmd=while true; do STATUS=$(${KUBERNETES_DISTRIBUTION_BINARY} rollout status deployment/${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} --timeout=180s); echo "$STATUS"; [[ "$STATUS" == *"successfully rolled out"* ]] && break; sleep 5; done
        ...    env=${env}
        ...    include_in_history=false
        ...    timeout_seconds=180
        ...    secret_file__kubeconfig=${kubeconfig}
        RW.Core.Add Pre To Report    ----------\nRollout Output:\n${rollout_status.stdout}
    END

    IF    ($rollout.stderr) != ""
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` should have rollout successfully
        ...    actual=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` did not rollout successfully
        ...    title=Deployment `${DEPLOYMENT_NAME}` in `${NAMESPACE}` did not rollout properly
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} generated the following output during restart attempt: \n${rollout.stderr}
        ...    next_steps=Inspect Deployment Warning Events for `${DEPLOYMENT_NAME}`\nEscalate rollout issues to service owner.
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Force Delete Pods in Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Force delete all pods related to the deployment
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
    RW.Core.Add Pre To Report    ----------\nPre delete log output:\n${logs.stdout}

    ${force_delete}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} delete pods -n ${NAMESPACE} --context ${CONTEXT} -l $(kubectl get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.template.metadata.labels}' | tr -d '{}" ' | tr ':' '=')
    ...    env=${env}
    ...    include_in_history=false
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    ----------\Force Delete Output:\n${force_delete.stdout}

    IF    ($force_delete.stderr) == ""
        ${force_delete_status}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods -n ${NAMESPACE} --context ${CONTEXT} -l $(kubectl get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.template.metadata.labels}' | tr -d '{}" ' | tr ':' '=')
        ...    env=${env}
        ...    include_in_history=false
        ...    timeout_seconds=180
        ...    secret_file__kubeconfig=${kubeconfig}
        RW.Core.Add Pre To Report    ----------\nNew pod creation output:\n${force_delete_status.stdout}
    END

    IF    ($force_delete.stderr) != ""
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` should have force deleted pods successfully
        ...    actual=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` did not force deleted pods successfully
        ...    title=Deployment `${DEPLOYMENT_NAME}` in `${NAMESPACE}` did not force deleted pods successfully
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} generated the following output during force deletion attempt: \n${force_delete.stderr}
        ...    next_steps=Inspect Deployment Warning Events for `${DEPLOYMENT_NAME}`\nEscalate pod deletion issues to service owner.
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Rollback Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}` to Previous Version
    [Documentation]    Perform a rollback to a known functional version
    [Tags]
    ...    log
    ...    pod
    ...    rollback
    ...    deployment
    ...    ${DEPLOYMENT_NAME}

    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} logs deployment/${DEPLOYMENT_NAME} --tail 50 -n ${NAMESPACE} --all-containers=true --max-log-requests=20 --context ${CONTEXT}
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    ----------\nPre restart log output:\n${logs.stdout}

    ${rollback}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} rollout undo deployment/${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT}
    ...    env=${env}
    ...    include_in_history=false
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    ----------\nRestart Output:\n${rollback.stdout}

    IF    ($rollback.stderr) == ""
        ${rollback_status}=    RW.CLI.Run Cli
        ...    cmd=while true; do STATUS=$(${KUBERNETES_DISTRIBUTION_BINARY} rollout status deployment/${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} --timeout=180s); echo "$STATUS"; [[ "$STATUS" == *"successfully rolled out"* ]] && break; sleep 5; done
        ...    env=${env}
        ...    include_in_history=false
        ...    timeout_seconds=180
        ...    secret_file__kubeconfig=${kubeconfig}
        RW.Core.Add Pre To Report    ----------\nRollout Output:\n${rollback_status.stdout}
    END

    IF    ($rollback.stderr) != ""
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` should have rollback successfully
        ...    actual=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` did not rollback successfully
        ...    title=Deployment `${DEPLOYMENT_NAME}` in `${NAMESPACE}` did not rollback properly
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} generated the following output during rollback attempt: \n${rollback.stderr}
        ...    next_steps=Inspect Deployment Warning Events for `${DEPLOYMENT_NAME}`\nEscalate rollback issues to service owner.
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Scale Down Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Stops all running pods in a deployment to immediately halt a failing or runaway service.
    [Tags]
    ...    log
    ...    pod
    ...    scaledown
    ...    deployment
    ...    ${DEPLOYMENT_NAME}

    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} logs deployment/${DEPLOYMENT_NAME} --tail 50 -n ${NAMESPACE} --all-containers=true --max-log-requests=20 --context ${CONTEXT}
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    ----------\nPre restart log output:\n${logs.stdout}

    ${scaledown}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} scale deployment/${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} --replicas=0
    ...    env=${env}
    ...    include_in_history=false
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    ----------\nRestart Output:\n${scaledown.stdout}

    IF    ($scaledown.stderr) != ""
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` should scale down successfully
        ...    actual=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` did not scale down successfully
        ...    title=Deployment `${DEPLOYMENT_NAME}` in `${NAMESPACE}` did not scale down properly
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} generated the following output during scaledown attempt: \n${scaledown.stderr}
        ...    next_steps=Inspect Deployment Warning Events for `${DEPLOYMENT_NAME}`\nEscalate rollback issues to service owner.
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Scale Up Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}` by ${SCALE_UP_FACTOR}x
    [Documentation]    Increase deployment replicas 
    [Tags]
    ...    scaleup
    ...    deployment
    ...    ${DEPLOYMENT_NAME}

    ${scaleup}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} scale deployment/${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} --replicas=0
    ...    env=${env}
    ...    include_in_history=false
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    ----------\nRestart Output:\n${scaledown.stdout}

    IF    ($scaleup.stderr) != ""
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` should scale down successfully
        ...    actual=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` did not scale down successfully
        ...    title=Deployment `${DEPLOYMENT_NAME}` in `${NAMESPACE}` did not scale down properly
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} generated the following output during scaledown attempt: \n${scaledown.stderr}
        ...    next_steps=Inspect Deployment Warning Events for `${DEPLOYMENT_NAME}`\nEscalate rollback issues to service owner.
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}


Clean Up Stale ReplicaSets for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Deletes all stale replicasets.
    [Tags]
    ...    replicaset
    ...    stale
    ...    deployment
    ...    ${DEPLOYMENT_NAME}

    ${rs_cleanup}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} delete rs -n ${NAMESPACE} --context ${CONTEXT} --selector=$(kubectl get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.selector.matchLabels}' | tr -d '{}" ' | tr ':' '=' | tr ',' ' ') --field-selector=status.replicas=0
    ...    env=${env}
    ...    include_in_history=false
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    ----------\nRestart Output:\n${rs_cleanup.stdout}

    IF    ($rs_cleanup.stderr) != ""
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` should has 1 active replicaset
        ...    actual=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` did not successfully clean up replicasets
        ...    title=Deployment `${DEPLOYMENT_NAME}` in `${NAMESPACE}` did not scale down properly
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} generated the following output during the replicaset cleanup attempt: \n${rs_cleanup.stderr}
        ...    next_steps=Check ReplicaSet Health for Deployment `${DEPLOYMENT_NAME}`\nEscalate rollback issues to service owner.
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}


Scale Down Stale ReplicaSets for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Finds any old/stale replicasets that still have active pods and scales them down.
    [Tags]
    ...    replicaset
    ...    stale
    ...    scaledown
    ...    deployment
    ...    ${DEPLOYMENT_NAME}

    ${rs_scaledown}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} scale rs -n ${NAMESPACE} --context ${CONTEXT} -l $(kubectl get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.selector.matchLabels}' | tr -d '{}" ' | tr ':' '=' | tr ',' ' ') --replicas=0
    ...    env=${env}
    ...    include_in_history=false
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    ----------\nScaleout Output:\n${rs_scaledown.stdout}

    IF    ($rs_scaledown.stderr) != ""
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` should has 1 active replicaset
        ...    actual=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` did not successfully scale down stale replicasets
        ...    title=Deployment `${DEPLOYMENT_NAME}` in `${NAMESPACE}` did not scale down properly
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} generated the following output during the stale replicaset scaledown attempt: \n${rs_scaledown.stderr}
        ...    next_steps=Check ReplicaSet Health for Deployment `${DEPLOYMENT_NAME}`\nEscalate rollback issues to service owner.
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
    ${SCALE_UP_FACTOR}=    RW.Core.Import User Variable    SCALE_UP_FACTOR
    ...    type=string
    ...    description=The multiple in which to increase the total amount of pods. For example, a deployment with 2 pods and a scale up factor of 2 will result in 4 pods. 
    ...    example=2
    ...    default=2
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${DEPLOYMENT_NAME}    ${DEPLOYMENT_NAME}
    Set Suite Variable    ${SCALE_UP_FACTOR}    ${SCALE_UP_FACTOR}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}", "DEPLOYMENT_NAME": "${DEPLOYMENT_NAME}"}