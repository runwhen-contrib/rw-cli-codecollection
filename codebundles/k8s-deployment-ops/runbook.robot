*** Settings ***
Documentation       Perform oprational tasks for a Kubernetes deployment.
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes Deployment Operations
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.NextSteps
Library             RW.K8sHelper
Library             OperatingSystem
Library             String
Library             DateTime

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
    ...    access:read-write

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
        
    ${timestamp}=    DateTime.Get Current Date
    IF    ($rollout.stderr) != ""
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` should have rollout successfully
        ...    actual=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` did not rollout successfully
        ...    title=Deployment `${DEPLOYMENT_NAME}` in `${NAMESPACE}` did not rollout properly
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} generated the following output during restart attempt: \n${rollout.stderr}
        ...    next_steps=Inspect Deployment Warning Events for `${DEPLOYMENT_NAME}`\nEscalate rollout issues to service owner.
        ...    observed_at=${timestamp}
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
    ...    access:read-write

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
    
    ${timestamp}=    DateTime.Get Current Date
    IF    ($force_delete.stderr) != ""
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` should have force deleted pods successfully
        ...    actual=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` did not force deleted pods successfully
        ...    title=Deployment `${DEPLOYMENT_NAME}` in `${NAMESPACE}` did not force deleted pods successfully
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} generated the following output during force deletion attempt: \n${force_delete.stderr}
        ...    next_steps=Inspect Deployment Warning Events for `${DEPLOYMENT_NAME}`\nEscalate pod deletion issues to service owner.
        ...    observed_at=${timestamp}
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
    ...    access:read-write

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
    
    ${timestamp}=    DateTime.Get Current Date
    IF    ($rollback.stderr) != ""
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` should have rollback successfully
        ...    actual=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` did not rollback successfully
        ...    title=Deployment `${DEPLOYMENT_NAME}` in `${NAMESPACE}` did not rollback properly
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} generated the following output during rollback attempt: \n${rollback.stderr}
        ...    next_steps=Inspect Deployment Warning Events for `${DEPLOYMENT_NAME}`\nEscalate rollback issues to service owner.
        ...    observed_at=${timestamp}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Scale Down Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Stops (or nearly stops) all running pods in a deployment to immediately halt a failing or runaway service.
    [Tags]
    ...    log
    ...    pod
    ...    scaledown
    ...    deployment
    ...    ${DEPLOYMENT_NAME}
    ...    access:read-write

    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} logs deployment/${DEPLOYMENT_NAME} --tail 50 -n ${NAMESPACE} --all-containers=true --max-log-requests=20 --context ${CONTEXT}
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    ----------\nPre restart log output:\n${logs.stdout}

    ${timestamp}=    DateTime.Get Current Date
    # Decide whether to allow zero replicas or just go to 1.
    IF    "${ALLOW_SCALE_TO_ZERO}" == "true"
        ${desired_replicas}=    Set Variable    0
    ELSE
        ${desired_replicas}=    Set Variable    1
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` can not scale to 0
        ...    actual=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` can not scale to 0
        ...    title=Deployment `${DEPLOYMENT_NAME}` in `${NAMESPACE}` is not permitted to scale to 0
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} is not permitted to scale to 0 due to CodeBundle configuration
        ...    next_steps=Reconfigure Codebundle if 0 replicas is desired. 
        ...    observed_at=${timestamp}
    END

    ${scaledown}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} scale deployment/${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} --replicas=${desired_replicas}
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}

    ${replicas}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} 
    ...    env=${env}
    ...    include_in_history=true
    ...    secret_file__kubeconfig=${kubeconfig}

    RW.Core.Add Pre To Report    ----------\nScale Down Output:\n${scaledown.stdout}\nRollout and Replicas:\n${replicas.stdout}

    IF    ($scaledown.stderr) != ""
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` should scale down successfully
        ...    actual=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` did not scale down successfully
        ...    title=Deployment `${DEPLOYMENT_NAME}` in `${NAMESPACE}` did not scale down properly
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} generated the following output during scaledown attempt: \n${scaledown.stderr}
        ...    next_steps=Inspect Deployment Warning Events for `${DEPLOYMENT_NAME}`\nEscalate rollback issues to service owner.
        ...    observed_at=${timestamp}
    END

    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}


Scale Up Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}` by ${SCALE_UP_FACTOR}x
    [Documentation]    Increase deployment replicas 
    [Tags]
    ...    scaleup
    ...    deployment
    ...    ${DEPLOYMENT_NAME}
    ...    access:read-write

    ${current_result}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.replicas}'
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=True
    ...    timeout_seconds=180
    ...    env=${env}

    # Convert the CLI output (stdout) to an integer
    ${current_replicas}=    Convert To Integer    ${current_result.stdout}

    # If current is 0, default to 1; otherwise multiply by the factor
    ${scaled}=    Evaluate    max(1, ${current_replicas} * ${SCALE_UP_FACTOR})
    
    ${timestamp}=    DateTime.Get Current Date
    IF     ${scaled} <= ${MAX_REPLICAS}
        ${scaleup}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} scale deployment/${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} --replicas=${scaled}
        ...    env=${env}
        ...    include_in_history=true
        ...    timeout_seconds=180
        ...    secret_file__kubeconfig=${kubeconfig}
        ${replicas}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} && ${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.replicas}'
        ...    env=${env}
        ...    include_in_history=true
        ...    secret_file__kubeconfig=${kubeconfig}
        RW.Core.Add Pre To Report    ----------\Scaleup Output:\n${scaleup.stdout}\nRollout and Replicas:\n${replicas.stdout}

        IF    ($scaleup.stderr) != ""
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` should scale up successfully
            ...    actual=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` did not scale up successfully
            ...    title=Deployment `${DEPLOYMENT_NAME}` in `${NAMESPACE}` did not scale up properly
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} generated the following output during scaledown attempt: \n${scaleup.stderr}
            ...    next_steps=Inspect Deployment Warning Events for `${DEPLOYMENT_NAME}`\nEscalate rollback issues to service owner.
            ...    observed_at=${timestamp}
        END
    ELSE
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` should scale up successfully
        ...    actual=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` did not scale up successfully
        ...    title=Can not Scale Up `${DEPLOYMENT_NAME}` in `${NAMESPACE}` beyond ${MAX_REPLICAS}
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} has ${current_replicas} replicas.
        ...    next_steps=Determine if `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}` should scale beyond ${MAX_REPLICAS} replias
        ...    observed_at=${timestamp}
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
    ...    access:read-write

    ${rs_cleanup}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get rs -n ${NAMESPACE} --context ${CONTEXT} --selector=$(${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.selector.matchLabels}' | tr -d '{}" ' | tr ':' '=') -o json | jq -r '.items[] | select(.status.replicas == 0) | .metadata.name' | while read -r rs; do ${KUBERNETES_DISTRIBUTION_BINARY} delete rs "$rs" -n ${NAMESPACE} --context ${CONTEXT}; done
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    ----------\Replicaset Cleanup Output:\n${rs_cleanup.stdout}

    ${timestamp}=    DateTime.Get Current Date
    IF    ($rs_cleanup.stderr) != ""
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` should has 1 active replicaset
        ...    actual=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` did not successfully clean up replicasets
        ...    title=Deployment `${DEPLOYMENT_NAME}` in `${NAMESPACE}` did not scale down properly
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} generated the following output during the replicaset cleanup attempt: \n${rs_cleanup.stderr}
        ...    next_steps=Check ReplicaSet Health for Deployment `${DEPLOYMENT_NAME}`\nEscalate replicaset cleanup issues to service owner.
        ...    observed_at=${timestamp}
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
    ...    access:read-write

    ${rs_scaledown}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} scale rs -n ${NAMESPACE} --context ${CONTEXT} -l $(${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.selector.matchLabels}' | tr -d '{}" ' | tr ':' '=') --replicas=0
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    ----------\nScaledown Replicaset Output:\n${rs_scaledown.stdout}

    ${timestamp}=    DateTime.Get Current Date
    IF    ($rs_scaledown.stderr) != ""
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` should has 1 active replicaset
        ...    actual=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` did not successfully scale down stale replicasets
        ...    title=Deployment `${DEPLOYMENT_NAME}` in `${NAMESPACE}` did not scale down properly
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} generated the following output during the stale replicaset scaledown attempt: \n${rs_scaledown.stderr}
        ...    next_steps=Check ReplicaSet Health for Deployment `${DEPLOYMENT_NAME}`\nEscalate rollback issues to service owner.
        ...    observed_at=${timestamp}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}


Scale Up HPA for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}` by ${HPA_SCALE_FACTOR}x
    [Documentation]    Increase HPA min and max replicas by a scaling factor
    [Tags]
    ...    hpa
    ...    scaleup
    ...    autoscaling
    ...    deployment
    ...    ${DEPLOYMENT_NAME}
    ...    access:read-write

    # Check if HPA exists for this deployment
    ${hpa_check}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get hpa -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.items[] | select(.spec.scaleTargetRef.name=="${DEPLOYMENT_NAME}" and (.spec.scaleTargetRef.kind=="Deployment" or .spec.scaleTargetRef.kind=="deployment")) | .metadata.name' | head -1
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    ${hpa_name}=    Strip String    ${hpa_check.stdout}
    ${timestamp}=    DateTime.Get Current Date
    IF    "${hpa_name}" == "" or $hpa_check.stderr != ""
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=HPA should exist for deployment `${DEPLOYMENT_NAME}`
        ...    actual=No HPA found for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    title=No HPA Found for Deployment `${DEPLOYMENT_NAME}`
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Cannot scale HPA - no HorizontalPodAutoscaler exists for deployment ${DEPLOYMENT_NAME}\n\nCommand output: ${hpa_check.stdout}\nErrors: ${hpa_check.stderr}
        ...    next_steps=Create an HPA for this deployment first\nOr use deployment scaling tasks instead\nVerify HPA scaleTargetRef matches deployment name exactly\nCheck namespace and context are correct
        ...    observed_at=${timestamp}
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Commands Used: ${history}
    ELSE
        RW.Core.Add Pre To Report    ----------\nFound HPA: ${hpa_name}

        # Check if HPA is managed by GitOps
        ${gitops_check}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get hpa ${hpa_name} -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r 'if (.metadata.labels // {} | to_entries | map(select(.key | test("flux|argocd|kustomize.toolkit.fluxcd.io"))) | length > 0) or (.metadata.annotations // {} | to_entries | map(select(.key | test("flux|argocd|gitops"))) | length > 0) then "true" else "false" end'
        ...    env=${env}
        ...    include_in_history=true
        ...    timeout_seconds=180
        ...    secret_file__kubeconfig=${kubeconfig}
        ${is_gitops_managed}=    Strip String    ${gitops_check.stdout}
        RW.Core.Add Pre To Report    ----------\nGitOps Management Check:\n${is_gitops_managed}

        # Get current HPA min and max replicas
        ${current_min}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get hpa ${hpa_name} -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.minReplicas}'
        ...    env=${env}
        ...    include_in_history=true
        ...    timeout_seconds=180
        ...    secret_file__kubeconfig=${kubeconfig}
        ${min_replicas}=    Convert To Integer    ${current_min.stdout}

        ${current_max}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get hpa ${hpa_name} -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.maxReplicas}'
        ...    env=${env}
        ...    include_in_history=true
        ...    timeout_seconds=180
        ...    secret_file__kubeconfig=${kubeconfig}
        ${max_replicas}=    Convert To Integer    ${current_max.stdout}

        RW.Core.Add Pre To Report    ----------\nCurrent HPA Configuration:\nMin Replicas: ${min_replicas}\nMax Replicas: ${max_replicas}

        # Calculate new values
        ${new_min}=    Evaluate    int(${min_replicas} * ${HPA_SCALE_FACTOR})
        ${new_max}=    Evaluate    int(${max_replicas} * ${HPA_SCALE_FACTOR})

        # Apply upper limit if specified
        IF    ${new_max} > ${HPA_MAX_REPLICAS}
            ${new_max}=    Set Variable    ${HPA_MAX_REPLICAS}
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=HPA max replicas should scale to ${new_max}
            ...    actual=HPA max replicas capped at ${HPA_MAX_REPLICAS}
            ...    title=HPA Max Replicas Capped at ${HPA_MAX_REPLICAS}
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=Scaled HPA max replicas capped at configured maximum: ${HPA_MAX_REPLICAS}
            ...    next_steps=Review HPA_MAX_REPLICAS configuration if higher scaling is needed
            ...    observed_at=${timestamp}
        END

        RW.Core.Add Pre To Report    ----------\nScaling HPA:\nMin Replicas: ${min_replicas} → ${new_min}\nMax Replicas: ${max_replicas} → ${new_max}

        # If GitOps managed, only suggest changes
        IF    $is_gitops_managed == "true"
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=HPA `${hpa_name}` should be updated via GitOps
            ...    actual=HPA `${hpa_name}` is managed by GitOps - changes should be made in Git repository
            ...    title=Suggestion: Scale Up HPA `${hpa_name}` via GitOps
            ...    reproduce_hint=View suggested patch in report output
            ...    details=HPA ${hpa_name} is managed by GitOps (Flux/ArgoCD). To scale up, update the HPA manifest in your Git repository:\n\nSuggested change:\nminReplicas: ${min_replicas} → ${new_min}\nmaxReplicas: ${max_replicas} → ${new_max}\n\nOr apply this patch (for manual override, not recommended):\nkubectl patch hpa ${hpa_name} -n ${NAMESPACE} --context ${CONTEXT} --patch '{"spec":{"minReplicas":${new_min},"maxReplicas":${new_max}}}'
            ...    next_steps=Update HPA manifest in Git repository\nCommit and push changes to trigger GitOps sync\nMonitor GitOps controller for deployment updates\nIf urgent, consider manual override (will be reverted by GitOps)
            ...    observed_at=${timestamp}
            ${history}=    RW.CLI.Pop Shell History
            RW.Core.Add Pre To Report    Commands Used: ${history}
        ELSE
            # Update HPA
            ${hpa_update}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} patch hpa ${hpa_name} -n ${NAMESPACE} --context ${CONTEXT} --patch '{"spec":{"minReplicas":${new_min},"maxReplicas":${new_max}}}'
        ...    env=${env}
        ...    include_in_history=true
        ...    timeout_seconds=180
        ...    secret_file__kubeconfig=${kubeconfig}
        RW.Core.Add Pre To Report    ----------\nHPA Update Result:\n${hpa_update.stdout}

        IF    ($hpa_update.stderr) != ""
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=HPA `${hpa_name}` should scale up successfully
            ...    actual=HPA `${hpa_name}` failed to scale up
            ...    title=Failed to Scale Up HPA `${hpa_name}`
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=Error scaling HPA: \n${hpa_update.stderr}
            ...    next_steps=Review HPA configuration and permissions\nVerify HPA settings are valid
            ...    observed_at=${timestamp}
        ELSE
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=HPA `${hpa_name}` scaling operation completed
            ...    actual=HPA `${hpa_name}` successfully scaled up by ${HPA_SCALE_FACTOR}x
            ...    title=HPA `${hpa_name}` Scaled Up Successfully
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=HPA ${hpa_name} for deployment ${DEPLOYMENT_NAME} in namespace ${NAMESPACE} was scaled up.\nPrevious: minReplicas=${min_replicas}, maxReplicas=${max_replicas}\nNew: minReplicas=${new_min}, maxReplicas=${new_max}
            ...    next_steps=Monitor deployment metrics to ensure HPA scaling meets demand\nConsider adjusting HPA metrics thresholds if needed
            ...    observed_at=${timestamp}
            END
        END

        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Commands Used: ${history}
    END


Scale Down HPA for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}` to Min ${HPA_MIN_REPLICAS}
    [Documentation]    Decrease HPA min and max replicas to specified minimum values or scale down by factor
    [Tags]
    ...    hpa
    ...    scaledown
    ...    autoscaling
    ...    deployment
    ...    ${DEPLOYMENT_NAME}
    ...    access:read-write

    # Check if HPA exists for this deployment
    ${hpa_check}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get hpa -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.items[] | select(.spec.scaleTargetRef.name=="${DEPLOYMENT_NAME}" and (.spec.scaleTargetRef.kind=="Deployment" or .spec.scaleTargetRef.kind=="deployment")) | .metadata.name' | head -1
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    ${hpa_name}=    Strip String    ${hpa_check.stdout}
    ${timestamp}=    DateTime.Get Current Date
    IF    "${hpa_name}" == "" or $hpa_check.stderr != ""
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=HPA should exist for deployment `${DEPLOYMENT_NAME}`
        ...    actual=No HPA found for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    title=No HPA Found for Deployment `${DEPLOYMENT_NAME}`
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Cannot scale HPA - no HorizontalPodAutoscaler exists for deployment ${DEPLOYMENT_NAME}\n\nCommand output: ${hpa_check.stdout}\nErrors: ${hpa_check.stderr}
        ...    next_steps=Create an HPA for this deployment first\nOr use deployment scaling tasks instead\nVerify HPA scaleTargetRef matches deployment name exactly\nCheck namespace and context are correct
        ...    observed_at=${timestamp}
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Commands Used: ${history}
    ELSE
        RW.Core.Add Pre To Report    ----------\nFound HPA: ${hpa_name}

        # Check if HPA is managed by GitOps
        ${gitops_check}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get hpa ${hpa_name} -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r 'if (.metadata.labels // {} | to_entries | map(select(.key | test("flux|argocd|kustomize.toolkit.fluxcd.io"))) | length > 0) or (.metadata.annotations // {} | to_entries | map(select(.key | test("flux|argocd|gitops"))) | length > 0) then "true" else "false" end'
        ...    env=${env}
        ...    include_in_history=true
        ...    timeout_seconds=180
        ...    secret_file__kubeconfig=${kubeconfig}
        ${is_gitops_managed}=    Strip String    ${gitops_check.stdout}
        RW.Core.Add Pre To Report    ----------\nGitOps Management Check:\n${is_gitops_managed}

        # Get current HPA min and max replicas
        ${current_min}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get hpa ${hpa_name} -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.minReplicas}'
        ...    env=${env}
        ...    include_in_history=true
        ...    timeout_seconds=180
        ...    secret_file__kubeconfig=${kubeconfig}
        ${min_replicas}=    Convert To Integer    ${current_min.stdout}

        ${current_max}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get hpa ${hpa_name} -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.maxReplicas}'
        ...    env=${env}
        ...    include_in_history=true
        ...    timeout_seconds=180
        ...    secret_file__kubeconfig=${kubeconfig}
        ${max_replicas}=    Convert To Integer    ${current_max.stdout}

        RW.Core.Add Pre To Report    ----------\nCurrent HPA Configuration:\nMin Replicas: ${min_replicas}\nMax Replicas: ${max_replicas}

        # Set to minimum values
        ${new_min}=    Set Variable    ${HPA_MIN_REPLICAS}
        ${new_max}=    Set Variable    ${HPA_MIN_REPLICAS}

        RW.Core.Add Pre To Report    ----------\nScaling Down HPA to Minimum:\nMin Replicas: ${min_replicas} → ${new_min}\nMax Replicas: ${max_replicas} → ${new_max}

        # If GitOps managed, only suggest changes
        IF    $is_gitops_managed == "true"
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=HPA `${hpa_name}` should be updated via GitOps
            ...    actual=HPA `${hpa_name}` is managed by GitOps - changes should be made in Git repository
            ...    title=Suggestion: Scale Down HPA `${hpa_name}` via GitOps
            ...    reproduce_hint=View suggested patch in report output
            ...    details=HPA ${hpa_name} is managed by GitOps (Flux/ArgoCD). To scale down, update the HPA manifest in your Git repository:\n\nSuggested change:\nminReplicas: ${min_replicas} → ${new_min}\nmaxReplicas: ${max_replicas} → ${new_max}\n\nOr apply this patch (for manual override, not recommended):\nkubectl patch hpa ${hpa_name} -n ${NAMESPACE} --context ${CONTEXT} --patch '{"spec":{"minReplicas":${new_min},"maxReplicas":${new_max}}}'
            ...    next_steps=Update HPA manifest in Git repository\nCommit and push changes to trigger GitOps sync\nMonitor GitOps controller for deployment updates\nIf urgent, consider manual override (will be reverted by GitOps)
            ...    observed_at=${timestamp}
            ${history}=    RW.CLI.Pop Shell History
            RW.Core.Add Pre To Report    Commands Used: ${history}
        ELSE
            # Update HPA
            ${hpa_update}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} patch hpa ${hpa_name} -n ${NAMESPACE} --context ${CONTEXT} --patch '{"spec":{"minReplicas":${new_min},"maxReplicas":${new_max}}}'
        ...    env=${env}
        ...    include_in_history=true
        ...    timeout_seconds=180
        ...    secret_file__kubeconfig=${kubeconfig}
        RW.Core.Add Pre To Report    ----------\nHPA Update Result:\n${hpa_update.stdout}

        IF    ($hpa_update.stderr) != ""
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=HPA `${hpa_name}` should scale down successfully
            ...    actual=HPA `${hpa_name}` failed to scale down
            ...    title=Failed to Scale Down HPA `${hpa_name}`
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=Error scaling down HPA: \n${hpa_update.stderr}
            ...    next_steps=Review HPA configuration and permissions\nVerify HPA settings are valid
            ...    observed_at=${timestamp}
        ELSE
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=HPA `${hpa_name}` scaling operation completed
            ...    actual=HPA `${hpa_name}` successfully scaled down to minimum
            ...    title=HPA `${hpa_name}` Scaled Down Successfully
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=HPA ${hpa_name} for deployment ${DEPLOYMENT_NAME} in namespace ${NAMESPACE} was scaled down to minimum.\nPrevious: minReplicas=${min_replicas}, maxReplicas=${max_replicas}\nNew: minReplicas=${new_min}, maxReplicas=${new_max}
            ...    next_steps=HPA is now constrained to ${HPA_MIN_REPLICAS} replicas\nScale up HPA when ready to resume normal autoscaling operations
            ...    observed_at=${timestamp}
            END
        END

        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Commands Used: ${history}
    END


Increase CPU Resources for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Intelligently increases CPU resources for a deployment based on VPA recommendations, HPA presence, or doubles current values. Does not apply if GitOps-managed or HPA exists.
    [Tags]
    ...    resources
    ...    cpu
    ...    vpa
    ...    hpa
    ...    deployment
    ...    ${DEPLOYMENT_NAME}
    ...    access:read-write

    # Test connectivity by checking if deployment exists
    ${deployment_check}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o name
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    ${timestamp}=    DateTime.Get Current Date
    IF    ($deployment_check.stderr) != ""
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Should be able to connect to Kubernetes cluster and access deployment `${DEPLOYMENT_NAME}`
        ...    actual=Failed to access deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    title=Cannot Access Deployment `${DEPLOYMENT_NAME}` - Connection or Permission Issue
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Error accessing deployment: ${deployment_check.stderr}
        ...    next_steps=Verify kubeconfig credentials are valid\nCheck network connectivity to the cluster\nVerify RBAC permissions to access deployments in namespace `${NAMESPACE}`\nConfirm deployment name and namespace are correct
        ...    observed_at=${timestamp}
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Commands Used: ${history}
    END

    # Check if deployment is managed by GitOps (Flux or ArgoCD)
    # Check both labels and annotations for GitOps indicators
    ${gitops_check}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r 'if (.metadata.labels // {} | to_entries | map(select(.key | test("flux|argocd|kustomize.toolkit.fluxcd.io"))) | length > 0) or (.metadata.annotations // {} | to_entries | map(select(.key | test("flux|argocd|gitops"))) | length > 0) then "true" else "false" end'
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    ${is_gitops_managed}=    Strip String    ${gitops_check.stdout}
    RW.Core.Add Pre To Report    ----------\nGitOps Management Check:\n${is_gitops_managed}

    # Check if HPA exists for this deployment
    ${hpa_check}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get hpa -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.items[] | select(.spec.scaleTargetRef.name=="${DEPLOYMENT_NAME}" and (.spec.scaleTargetRef.kind=="Deployment" or .spec.scaleTargetRef.kind=="deployment")) | .metadata.name' | head -1 || echo ""
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    ${hpa_exists}=    Strip String    ${hpa_check.stdout}
    RW.Core.Add Pre To Report    ----------\nHPA Check:\n${hpa_exists}

    # Check if VPA exists with recommendations
    ${vpa_check}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get vpa -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.items[] | select(.spec.targetRef.name=="${DEPLOYMENT_NAME}") | .status.recommendation.containerRecommendations[0].upperBound.cpu' 2>/dev/null || echo ""
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    ${vpa_cpu_recommendation}=    Strip String    ${vpa_check.stdout}
    RW.Core.Add Pre To Report    ----------\nVPA CPU Recommendation Check:\n${vpa_cpu_recommendation}

    # Get current CPU request and limit
    ${current_cpu}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}'
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    ${current_cpu_value}=    Strip String    ${current_cpu.stdout}
    
    ${current_cpu_limit}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}'
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    ${current_cpu_limit_value}=    Strip String    ${current_cpu_limit.stdout}
    RW.Core.Add Pre To Report    ----------\nCurrent CPU Request: ${current_cpu_value}\nCurrent CPU Limit: ${current_cpu_limit_value}

    # Determine new CPU values
    ${new_cpu_value}=    Set Variable    ${EMPTY}
    ${new_cpu_limit_value}=    Set Variable    ${EMPTY}
    ${suggestion_only}=    Set Variable    ${FALSE}

    IF    $is_gitops_managed == "true"
        ${suggestion_only}=    Set Variable    ${TRUE}
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Deployment `${DEPLOYMENT_NAME}` should allow automatic resource updates
        ...    actual=Deployment `${DEPLOYMENT_NAME}` is managed by GitOps and requires manual updates
        ...    title=Deployment `${DEPLOYMENT_NAME}` is GitOps-managed - Manual Update Required
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} is managed by GitOps (Flux/ArgoCD). Resource changes should be made in the Git repository.
        ...    next_steps=Update resource requests in the Git repository that manages this deployment.
        ...    observed_at=${timestamp}
    END

    IF    $hpa_exists != ""
        ${suggestion_only}=    Set Variable    ${TRUE}
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Deployment `${DEPLOYMENT_NAME}` should allow resource updates
        ...    actual=Deployment `${DEPLOYMENT_NAME}` has an HPA configured
        ...    title=Deployment `${DEPLOYMENT_NAME}` has HPA - Resource Update Not Recommended
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} has an HPA: ${hpa_exists}. Changing resources may affect HPA behavior.
        ...    next_steps=Review HPA configuration before modifying CPU resources. Consider adjusting HPA thresholds instead.
        ...    observed_at=${timestamp}
    END

    IF    $vpa_cpu_recommendation != ""
        ${new_cpu_value}=    Set Variable    ${vpa_cpu_recommendation}
        ${new_cpu_limit_value}=    Set Variable    ${vpa_cpu_recommendation}
        RW.Core.Add Pre To Report    ----------\nVPA Upper Bound Recommendation for CPU: ${new_cpu_value}
    ELSE IF    $current_cpu_value != ""
        # Parse CPU request: convert to millicores for calculation
        # Kubernetes formats: "1" = 1000m, "0.5" = 500m, "100m" = 100m
        ${cpu_in_millicores}=    Evaluate    int(float("${current_cpu_value}".replace("m","")) * 1000) if not "${current_cpu_value}".endswith("m") else int("${current_cpu_value}".replace("m",""))
        ${new_cpu_millicores}=    Evaluate    int(${cpu_in_millicores} * 2)
        ${new_cpu_value}=    Set Variable    ${new_cpu_millicores}m
        
        IF    $current_cpu_limit_value != ""
            ${cpu_limit_in_millicores}=    Evaluate    int(float("${current_cpu_limit_value}".replace("m","")) * 1000) if not "${current_cpu_limit_value}".endswith("m") else int("${current_cpu_limit_value}".replace("m",""))
            ${new_cpu_limit_millicores}=    Evaluate    int(${cpu_limit_in_millicores} * 2)
            ${new_cpu_limit_value}=    Set Variable    ${new_cpu_limit_millicores}m
        END
        
        # Report message based on whether this is suggestion-only or will be applied
        IF    $suggestion_only
            IF    $new_cpu_limit_value != ""
                RW.Core.Add Pre To Report    ----------\nSuggested CPU Resources (2x current):\nRequest: ${new_cpu_value}\nLimit: ${new_cpu_limit_value}
            ELSE
                RW.Core.Add Pre To Report    ----------\nSuggested CPU Resources (2x current):\nRequest: ${new_cpu_value}\nLimit: Not set
            END
        ELSE
            IF    $new_cpu_limit_value != ""
                RW.Core.Add Pre To Report    ----------\nDoubling CPU Resources:\nRequest: ${current_cpu_value} → ${new_cpu_value}\nLimit: ${current_cpu_limit_value} → ${new_cpu_limit_value}
            ELSE
                RW.Core.Add Pre To Report    ----------\nDoubling CPU Resources:\nRequest: ${current_cpu_value} → ${new_cpu_value}\nLimit: Not currently set
            END
        END
    ELSE
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Deployment `${DEPLOYMENT_NAME}` should have CPU resource requests configured
        ...    actual=Deployment `${DEPLOYMENT_NAME}` has no CPU resource requests set
        ...    title=Deployment `${DEPLOYMENT_NAME}` Missing CPU Resource Requests
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} does not have CPU resource requests configured. No VPA recommendations available.
        ...    next_steps=Manually configure CPU resource requests for the deployment.\nConsider setting initial values like: cpu: 100m for small workloads, cpu: 500m for medium workloads.\nRefer to: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
        ...    observed_at=${timestamp}
    END

    IF    not $suggestion_only and $new_cpu_value != ""
        # Build the resource update command with both requests and limits
        ${limits_arg}=    Set Variable    ${EMPTY}
        IF    $new_cpu_limit_value != ""
            ${limits_arg}=    Set Variable    ${SPACE}--limits=cpu=${new_cpu_limit_value}
        END
        ${patch_cmd}=    Set Variable    ${KUBERNETES_DISTRIBUTION_BINARY} set resources deployment/${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} --requests=cpu=${new_cpu_value}${limits_arg}
        ${resource_update}=    RW.CLI.Run Cli
        ...    cmd=${patch_cmd}
        ...    env=${env}
        ...    include_in_history=true
        ...    timeout_seconds=180
        ...    secret_file__kubeconfig=${kubeconfig}
        RW.Core.Add Pre To Report    ----------\nCPU Resource Update Applied:\n${resource_update.stdout}
        
        IF    ($resource_update.stderr) != ""
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Deployment `${DEPLOYMENT_NAME}` CPU resources should update successfully
            ...    actual=Deployment `${DEPLOYMENT_NAME}` CPU resource update failed
            ...    title=Failed to Update CPU Resources for `${DEPLOYMENT_NAME}`
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=Error updating CPU resources: \n${resource_update.stderr}
            ...    next_steps=Review deployment configuration and permissions\nManually update CPU resources if needed
            ...    observed_at=${timestamp}
        ELSE
            ${limit_detail}=    Set Variable If    $new_cpu_limit_value != ""    \nLimit: ${current_cpu_limit_value} → ${new_cpu_limit_value}    \nLimit: Not currently set
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Deployment `${DEPLOYMENT_NAME}` CPU resources updated
            ...    actual=Deployment `${DEPLOYMENT_NAME}` CPU resources updated successfully
            ...    title=CPU Resources Updated for `${DEPLOYMENT_NAME}`
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=CPU resources for deployment ${DEPLOYMENT_NAME} in namespace ${NAMESPACE} were updated.\nRequest: ${current_cpu_value} → ${new_cpu_value}${limit_detail}
            ...    next_steps=Monitor deployment performance and pod resource utilization\nAdjust resources further if needed based on observed metrics
            ...    observed_at=${timestamp}
        END
    ELSE IF    $new_cpu_value != ""
        ${limits_suggestion}=    Set Variable    ${EMPTY}
        IF    $new_cpu_limit_value != ""
            ${limits_suggestion}=    Set Variable    ${SPACE}--limits=cpu=${new_cpu_limit_value}
        END
        RW.Core.Add Pre To Report    ----------\nSuggested CPU Resource Update (Not Applied):\nRun: ${KUBERNETES_DISTRIBUTION_BINARY} set resources deployment/${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} --requests=cpu=${new_cpu_value}${limits_suggestion}
    END

    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}


Increase Memory Resources for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Intelligently increases memory resources for a deployment based on VPA recommendations, HPA presence, or doubles current values. Does not apply if GitOps-managed or HPA exists.
    [Tags]
    ...    resources
    ...    memory
    ...    vpa
    ...    hpa
    ...    deployment
    ...    ${DEPLOYMENT_NAME}
    ...    access:read-write

    # Test connectivity by checking if deployment exists
    ${deployment_check}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o name
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    ${timestamp}=    DateTime.Get Current Date
    IF    ($deployment_check.stderr) != ""
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Should be able to connect to Kubernetes cluster and access deployment `${DEPLOYMENT_NAME}`
        ...    actual=Failed to access deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    title=Cannot Access Deployment `${DEPLOYMENT_NAME}` - Connection or Permission Issue
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Error accessing deployment: ${deployment_check.stderr}
        ...    next_steps=Verify kubeconfig credentials are valid\nCheck network connectivity to the cluster\nVerify RBAC permissions to access deployments in namespace `${NAMESPACE}`\nConfirm deployment name and namespace are correct
        ...    observed_at=${timestamp}
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Commands Used: ${history}
    END

    # Check if deployment is managed by GitOps (Flux or ArgoCD)
    # Check both labels and annotations for GitOps indicators
    ${gitops_check}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r 'if (.metadata.labels // {} | to_entries | map(select(.key | test("flux|argocd|kustomize.toolkit.fluxcd.io"))) | length > 0) or (.metadata.annotations // {} | to_entries | map(select(.key | test("flux|argocd|gitops"))) | length > 0) then "true" else "false" end'
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    ${is_gitops_managed}=    Strip String    ${gitops_check.stdout}
    RW.Core.Add Pre To Report    ----------\nGitOps Management Check:\n${is_gitops_managed}

    # Check if HPA exists for this deployment
    ${hpa_check}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get hpa -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.items[] | select(.spec.scaleTargetRef.name=="${DEPLOYMENT_NAME}" and (.spec.scaleTargetRef.kind=="Deployment" or .spec.scaleTargetRef.kind=="deployment")) | .metadata.name' | head -1 || echo ""
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    ${hpa_exists}=    Strip String    ${hpa_check.stdout}
    RW.Core.Add Pre To Report    ----------\nHPA Check:\n${hpa_exists}

    # Check if VPA exists with recommendations
    ${vpa_check}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get vpa -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.items[] | select(.spec.targetRef.name=="${DEPLOYMENT_NAME}") | .status.recommendation.containerRecommendations[0].upperBound.memory' 2>/dev/null || echo ""
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    ${vpa_memory_recommendation}=    Strip String    ${vpa_check.stdout}
    RW.Core.Add Pre To Report    ----------\nVPA Memory Recommendation Check:\n${vpa_memory_recommendation}

    # Get current memory request and limit
    ${current_memory}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}'
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    ${current_memory_value}=    Strip String    ${current_memory.stdout}
    
    ${current_memory_limit}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    ${current_memory_limit_value}=    Strip String    ${current_memory_limit.stdout}
    RW.Core.Add Pre To Report    ----------\nCurrent Memory Request: ${current_memory_value}\nCurrent Memory Limit: ${current_memory_limit_value}

    # Determine new memory values
    ${new_memory_value}=    Set Variable    ${EMPTY}
    ${new_memory_limit_value}=    Set Variable    ${EMPTY}
    ${suggestion_only}=    Set Variable    ${FALSE}

    IF    $is_gitops_managed == "true"
        ${suggestion_only}=    Set Variable    ${TRUE}
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Deployment `${DEPLOYMENT_NAME}` should allow automatic resource updates
        ...    actual=Deployment `${DEPLOYMENT_NAME}` is managed by GitOps and requires manual updates
        ...    title=Deployment `${DEPLOYMENT_NAME}` is GitOps-managed - Manual Update Required
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} is managed by GitOps (Flux/ArgoCD). Resource changes should be made in the Git repository.
        ...    next_steps=Update resource requests in the Git repository that manages this deployment.
        ...    observed_at=${timestamp}
    END

    IF    $hpa_exists != ""
        ${suggestion_only}=    Set Variable    ${TRUE}
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Deployment `${DEPLOYMENT_NAME}` should allow resource updates
        ...    actual=Deployment `${DEPLOYMENT_NAME}` has an HPA configured
        ...    title=Deployment `${DEPLOYMENT_NAME}` has HPA - Resource Update Not Recommended
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} has an HPA: ${hpa_exists}. Changing resources may affect HPA behavior.
        ...    next_steps=Review HPA configuration before modifying memory resources. Consider adjusting HPA thresholds instead.
        ...    observed_at=${timestamp}
    END

    IF    $vpa_memory_recommendation != ""
        ${new_memory_value}=    Set Variable    ${vpa_memory_recommendation}
        ${new_memory_limit_value}=    Set Variable    ${vpa_memory_recommendation}
        RW.Core.Add Pre To Report    ----------\nVPA Upper Bound Recommendation for Memory: ${new_memory_value}
    ELSE IF    $current_memory_value != ""
        # Parse memory request: detect unit BEFORE stripping, convert to Mi for calculation
        # Kubernetes formats: Mi (mebibytes), Gi (gibibytes), M (megabytes), G (gigabytes), Ki, k, etc.
        ${memory_in_mi}=    Evaluate    int(float("${current_memory_value}".replace("Gi","")) * 1024) if "Gi" in "${current_memory_value}" else (int(float("${current_memory_value}".replace("G","")) * 1000) if ("G" in "${current_memory_value}" and "Gi" not in "${current_memory_value}") else (int(float("${current_memory_value}".replace("Mi",""))) if "Mi" in "${current_memory_value}" else (int(float("${current_memory_value}".replace("M",""))) if "M" in "${current_memory_value}" else int(float("${current_memory_value}".replace("Ki","")) / 1024))))
        ${new_memory_mi}=    Evaluate    int(${memory_in_mi} * 2)
        ${new_memory_value}=    Set Variable    ${new_memory_mi}Mi
        
        IF    $current_memory_limit_value != ""
            ${memory_limit_in_mi}=    Evaluate    int(float("${current_memory_limit_value}".replace("Gi","")) * 1024) if "Gi" in "${current_memory_limit_value}" else (int(float("${current_memory_limit_value}".replace("G","")) * 1000) if ("G" in "${current_memory_limit_value}" and "Gi" not in "${current_memory_limit_value}") else (int(float("${current_memory_limit_value}".replace("Mi",""))) if "Mi" in "${current_memory_limit_value}" else (int(float("${current_memory_limit_value}".replace("M",""))) if "M" in "${current_memory_limit_value}" else int(float("${current_memory_limit_value}".replace("Ki","")) / 1024))))
            ${new_memory_limit_mi}=    Evaluate    int(${memory_limit_in_mi} * 2)
            ${new_memory_limit_value}=    Set Variable    ${new_memory_limit_mi}Mi
        END
        
        # Report message based on whether this is suggestion-only or will be applied
        IF    $suggestion_only
            IF    $new_memory_limit_value != ""
                RW.Core.Add Pre To Report    ----------\nSuggested Memory Resources (2x current):\nRequest: ${new_memory_value}\nLimit: ${new_memory_limit_value}
            ELSE
                RW.Core.Add Pre To Report    ----------\nSuggested Memory Resources (2x current):\nRequest: ${new_memory_value}\nLimit: Not set
            END
        ELSE
            IF    $new_memory_limit_value != ""
                RW.Core.Add Pre To Report    ----------\nDoubling Memory Resources:\nRequest: ${current_memory_value} → ${new_memory_value}\nLimit: ${current_memory_limit_value} → ${new_memory_limit_value}
            ELSE
                RW.Core.Add Pre To Report    ----------\nDoubling Memory Resources:\nRequest: ${current_memory_value} → ${new_memory_value}\nLimit: Not currently set
            END
        END
    ELSE
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Deployment `${DEPLOYMENT_NAME}` should have memory resource requests configured
        ...    actual=Deployment `${DEPLOYMENT_NAME}` has no memory resource requests set
        ...    title=Deployment `${DEPLOYMENT_NAME}` Missing Memory Resource Requests
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} does not have memory resource requests configured. No VPA recommendations available.
        ...    next_steps=Manually configure memory resource requests for the deployment.\nConsider setting initial values like: memory: 128Mi for small workloads, memory: 512Mi for medium workloads.\nRefer to: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
        ...    observed_at=${timestamp}
    END

    IF    not $suggestion_only and $new_memory_value != ""
        # Build the resource update command with both requests and limits
        ${limits_arg}=    Set Variable    ${EMPTY}
        IF    $new_memory_limit_value != ""
            ${limits_arg}=    Set Variable    ${SPACE}--limits=memory=${new_memory_limit_value}
        END
        ${patch_cmd}=    Set Variable    ${KUBERNETES_DISTRIBUTION_BINARY} set resources deployment/${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} --requests=memory=${new_memory_value}${limits_arg}
        ${resource_update}=    RW.CLI.Run Cli
        ...    cmd=${patch_cmd}
        ...    env=${env}
        ...    include_in_history=true
        ...    timeout_seconds=180
        ...    secret_file__kubeconfig=${kubeconfig}
        RW.Core.Add Pre To Report    ----------\nMemory Resource Update Applied:\n${resource_update.stdout}
        
        IF    ($resource_update.stderr) != ""
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Deployment `${DEPLOYMENT_NAME}` memory resources should update successfully
            ...    actual=Deployment `${DEPLOYMENT_NAME}` memory resource update failed
            ...    title=Failed to Update Memory Resources for `${DEPLOYMENT_NAME}`
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=Error updating memory resources: \n${resource_update.stderr}
            ...    next_steps=Review deployment configuration and permissions\nManually update memory resources if needed
            ...    observed_at=${timestamp}
        ELSE
            ${limit_detail}=    Set Variable If    $new_memory_limit_value != ""    \nLimit: ${current_memory_limit_value} → ${new_memory_limit_value}    \nLimit: Not currently set
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Deployment `${DEPLOYMENT_NAME}` memory resources updated
            ...    actual=Deployment `${DEPLOYMENT_NAME}` memory resources updated successfully
            ...    title=Memory Resources Updated for `${DEPLOYMENT_NAME}`
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=Memory resources for deployment ${DEPLOYMENT_NAME} in namespace ${NAMESPACE} were updated.\nRequest: ${current_memory_value} → ${new_memory_value}${limit_detail}
            ...    next_steps=Monitor deployment performance and pod memory utilization\nAdjust resources further if needed based on observed metrics\nWatch for OOMKilled events
            ...    observed_at=${timestamp}
        END
    ELSE IF    $new_memory_value != ""
        ${limits_suggestion}=    Set Variable    ${EMPTY}
        IF    $new_memory_limit_value != ""
            ${limits_suggestion}=    Set Variable    ${SPACE}--limits=memory=${new_memory_limit_value}
        END
        RW.Core.Add Pre To Report    ----------\nSuggested Memory Resource Update (Not Applied):\nRun: ${KUBERNETES_DISTRIBUTION_BINARY} set resources deployment/${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} --requests=memory=${new_memory_value}${limits_suggestion}
    END

    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}


Decrease CPU Resources for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Intelligently decreases CPU resources for a deployment by dividing current values by scale down factor. Does not apply if GitOps-managed or HPA exists.
    [Tags]
    ...    resources
    ...    cpu
    ...    scaledown
    ...    deployment
    ...    ${DEPLOYMENT_NAME}
    ...    access:read-write

    # Test connectivity by checking if deployment exists
    ${deployment_check}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o name
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    ${timestamp}=    DateTime.Get Current Date
    IF    ($deployment_check.stderr) != ""
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Should be able to connect to Kubernetes cluster and access deployment `${DEPLOYMENT_NAME}`
        ...    actual=Failed to access deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    title=Cannot Access Deployment `${DEPLOYMENT_NAME}` - Connection or Permission Issue
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Error accessing deployment: ${deployment_check.stderr}
        ...    next_steps=Verify kubeconfig credentials are valid\nCheck network connectivity to the cluster\nVerify RBAC permissions to access deployments in namespace `${NAMESPACE}`\nConfirm deployment name and namespace are correct
        ...    observed_at=${timestamp}
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Commands Used: ${history}
    END

    # Check if deployment is managed by GitOps (Flux or ArgoCD)
    ${gitops_check}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r 'if (.metadata.labels // {} | to_entries | map(select(.key | test("flux|argocd|kustomize.toolkit.fluxcd.io"))) | length > 0) or (.metadata.annotations // {} | to_entries | map(select(.key | test("flux|argocd|gitops"))) | length > 0) then "true" else "false" end'
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    ${is_gitops_managed}=    Strip String    ${gitops_check.stdout}
    RW.Core.Add Pre To Report    ----------\nGitOps Management Check:\n${is_gitops_managed}

    # Check if HPA exists for this deployment
    ${hpa_check}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get hpa -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.items[] | select(.spec.scaleTargetRef.name=="${DEPLOYMENT_NAME}" and (.spec.scaleTargetRef.kind=="Deployment" or .spec.scaleTargetRef.kind=="deployment")) | .metadata.name' | head -1 || echo ""
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    ${hpa_exists}=    Strip String    ${hpa_check.stdout}
    RW.Core.Add Pre To Report    ----------\nHPA Check:\n${hpa_exists}

    # Get current CPU request and limit
    ${current_cpu}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}'
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    ${current_cpu_value}=    Strip String    ${current_cpu.stdout}
    
    ${current_cpu_limit}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}'
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    ${current_cpu_limit_value}=    Strip String    ${current_cpu_limit.stdout}
    RW.Core.Add Pre To Report    ----------\nCurrent CPU Request: ${current_cpu_value}\nCurrent CPU Limit: ${current_cpu_limit_value}

    # Determine new CPU values
    ${new_cpu_value}=    Set Variable    ${EMPTY}
    ${new_cpu_limit_value}=    Set Variable    ${EMPTY}
    ${suggestion_only}=    Set Variable    ${FALSE}

    IF    $is_gitops_managed == "true"
        ${suggestion_only}=    Set Variable    ${TRUE}
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Deployment `${DEPLOYMENT_NAME}` should allow automatic resource updates
        ...    actual=Deployment `${DEPLOYMENT_NAME}` is managed by GitOps and requires manual updates
        ...    title=Deployment `${DEPLOYMENT_NAME}` is GitOps-managed - Manual Update Required
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} is managed by GitOps (Flux/ArgoCD). Resource changes should be made in the Git repository.
        ...    next_steps=Update resource requests in the Git repository that manages this deployment.
        ...    observed_at=${timestamp}
    END

    IF    $hpa_exists != ""
        ${suggestion_only}=    Set Variable    ${TRUE}
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Deployment `${DEPLOYMENT_NAME}` should allow resource updates
        ...    actual=Deployment `${DEPLOYMENT_NAME}` has an HPA configured
        ...    title=Deployment `${DEPLOYMENT_NAME}` has HPA - Resource Update Not Recommended
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} has an HPA: ${hpa_exists}. Changing resources may affect HPA behavior.
        ...    next_steps=Review HPA configuration before modifying CPU resources. Consider adjusting HPA thresholds instead.
        ...    observed_at=${timestamp}
    END

    IF    $current_cpu_value != ""
        # Parse CPU request: convert to millicores for calculation
        # Kubernetes formats: "1" = 1000m, "0.5" = 500m, "100m" = 100m
        ${cpu_in_millicores}=    Evaluate    int(float("${current_cpu_value}".replace("m","")) * 1000) if not "${current_cpu_value}".endswith("m") else int("${current_cpu_value}".replace("m",""))
        ${new_cpu_millicores}=    Evaluate    max(10, int(${cpu_in_millicores} / ${RESOURCE_SCALE_DOWN_FACTOR}))
        ${new_cpu_value}=    Set Variable    ${new_cpu_millicores}m
        
        IF    $current_cpu_limit_value != ""
            ${cpu_limit_in_millicores}=    Evaluate    int(float("${current_cpu_limit_value}".replace("m","")) * 1000) if not "${current_cpu_limit_value}".endswith("m") else int("${current_cpu_limit_value}".replace("m",""))
            ${new_cpu_limit_millicores}=    Evaluate    max(10, int(${cpu_limit_in_millicores} / ${RESOURCE_SCALE_DOWN_FACTOR}))
            ${new_cpu_limit_value}=    Set Variable    ${new_cpu_limit_millicores}m
        END
        
        # Report message based on whether this is suggestion-only or will be applied
        IF    $suggestion_only
            IF    $new_cpu_limit_value != ""
                RW.Core.Add Pre To Report    ----------\nSuggested CPU Resources (÷${RESOURCE_SCALE_DOWN_FACTOR}):\nRequest: ${new_cpu_value}\nLimit: ${new_cpu_limit_value}
            ELSE
                RW.Core.Add Pre To Report    ----------\nSuggested CPU Resources (÷${RESOURCE_SCALE_DOWN_FACTOR}):\nRequest: ${new_cpu_value}\nLimit: Not set
            END
        ELSE
            IF    $new_cpu_limit_value != ""
                RW.Core.Add Pre To Report    ----------\nDecreasing CPU Resources:\nRequest: ${current_cpu_value} → ${new_cpu_value}\nLimit: ${current_cpu_limit_value} → ${new_cpu_limit_value}
            ELSE
                RW.Core.Add Pre To Report    ----------\nDecreasing CPU Resources:\nRequest: ${current_cpu_value} → ${new_cpu_value}\nLimit: Not currently set
            END
        END
    ELSE
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Deployment `${DEPLOYMENT_NAME}` should have CPU resource requests configured
        ...    actual=Deployment `${DEPLOYMENT_NAME}` has no CPU resource requests set
        ...    title=Deployment `${DEPLOYMENT_NAME}` Missing CPU Resource Requests
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} does not have CPU resource requests configured.
        ...    next_steps=Cannot decrease resources - no current CPU requests found\nManually configure CPU resource requests for the deployment first
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Commands Used: ${history}
    END

    IF    not $suggestion_only and $new_cpu_value != ""
        # Build the resource update command with both requests and limits
        ${limits_arg}=    Set Variable    ${EMPTY}
        IF    $new_cpu_limit_value != ""
            ${limits_arg}=    Set Variable    ${SPACE}--limits=cpu=${new_cpu_limit_value}
        END
        ${patch_cmd}=    Set Variable    ${KUBERNETES_DISTRIBUTION_BINARY} set resources deployment/${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} --requests=cpu=${new_cpu_value}${limits_arg}
        ${resource_update}=    RW.CLI.Run Cli
        ...    cmd=${patch_cmd}
        ...    env=${env}
        ...    include_in_history=true
        ...    timeout_seconds=180
        ...    secret_file__kubeconfig=${kubeconfig}
        RW.Core.Add Pre To Report    ----------\nCPU Resource Update Applied:\n${resource_update.stdout}
        
        IF    ($resource_update.stderr) != ""
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Deployment `${DEPLOYMENT_NAME}` CPU resources should update successfully
            ...    actual=Deployment `${DEPLOYMENT_NAME}` CPU resource update failed
            ...    title=Failed to Decrease CPU Resources for `${DEPLOYMENT_NAME}`
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=Error updating CPU resources: \n${resource_update.stderr}
            ...    next_steps=Review deployment configuration and permissions\nManually update CPU resources if needed
            ...    observed_at=${timestamp}
        ELSE
            ${limit_detail}=    Set Variable If    $new_cpu_limit_value != ""    \nLimit: ${current_cpu_limit_value} → ${new_cpu_limit_value}    \nLimit: Not currently set
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Deployment `${DEPLOYMENT_NAME}` CPU resources decreased
            ...    actual=Deployment `${DEPLOYMENT_NAME}` CPU resources decreased successfully
            ...    title=CPU Resources Decreased for `${DEPLOYMENT_NAME}`
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=CPU resources for deployment ${DEPLOYMENT_NAME} in namespace ${NAMESPACE} were decreased by ${RESOURCE_SCALE_DOWN_FACTOR}x.\nRequest: ${current_cpu_value} → ${new_cpu_value}${limit_detail}
            ...    next_steps=Monitor deployment performance for CPU throttling\nIncrease resources if performance degrades\nConsider setting PodDisruptionBudgets to maintain availability
            ...    observed_at=${timestamp}
        END
    ELSE IF    $new_cpu_value != ""
        ${limits_suggestion}=    Set Variable    ${EMPTY}
        IF    $new_cpu_limit_value != ""
            ${limits_suggestion}=    Set Variable    ${SPACE}--limits=cpu=${new_cpu_limit_value}
        END
        RW.Core.Add Pre To Report    ----------\nSuggested CPU Resource Update (Not Applied):\nRun: ${KUBERNETES_DISTRIBUTION_BINARY} set resources deployment/${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} --requests=cpu=${new_cpu_value}${limits_suggestion}
    END

    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}


Decrease Memory Resources for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Intelligently decreases memory resources for a deployment by dividing current values by scale down factor. Does not apply if GitOps-managed or HPA exists.
    [Tags]
    ...    resources
    ...    memory
    ...    scaledown
    ...    deployment
    ...    ${DEPLOYMENT_NAME}
    ...    access:read-write

    # Test connectivity by checking if deployment exists
    ${deployment_check}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o name
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    ${timestamp}=    DateTime.Get Current Date
    IF    ($deployment_check.stderr) != ""
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Should be able to connect to Kubernetes cluster and access deployment `${DEPLOYMENT_NAME}`
        ...    actual=Failed to access deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    title=Cannot Access Deployment `${DEPLOYMENT_NAME}` - Connection or Permission Issue
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Error accessing deployment: ${deployment_check.stderr}
        ...    next_steps=Verify kubeconfig credentials are valid\nCheck network connectivity to the cluster\nVerify RBAC permissions to access deployments in namespace `${NAMESPACE}`\nConfirm deployment name and namespace are correct
        ...    observed_at=${timestamp}
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Commands Used: ${history}
    END

    # Check if deployment is managed by GitOps (Flux or ArgoCD)
    ${gitops_check}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r 'if (.metadata.labels // {} | to_entries | map(select(.key | test("flux|argocd|kustomize.toolkit.fluxcd.io"))) | length > 0) or (.metadata.annotations // {} | to_entries | map(select(.key | test("flux|argocd|gitops"))) | length > 0) then "true" else "false" end'
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    ${is_gitops_managed}=    Strip String    ${gitops_check.stdout}
    RW.Core.Add Pre To Report    ----------\nGitOps Management Check:\n${is_gitops_managed}

    # Check if HPA exists for this deployment
    ${hpa_check}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get hpa -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.items[] | select(.spec.scaleTargetRef.name=="${DEPLOYMENT_NAME}" and (.spec.scaleTargetRef.kind=="Deployment" or .spec.scaleTargetRef.kind=="deployment")) | .metadata.name' | head -1 || echo ""
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    ${hpa_exists}=    Strip String    ${hpa_check.stdout}
    RW.Core.Add Pre To Report    ----------\nHPA Check:\n${hpa_exists}

    # Get current memory request and limit
    ${current_memory}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}'
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    ${current_memory_value}=    Strip String    ${current_memory.stdout}
    
    ${current_memory_limit}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
    ...    env=${env}
    ...    include_in_history=true
    ...    timeout_seconds=180
    ...    secret_file__kubeconfig=${kubeconfig}
    ${current_memory_limit_value}=    Strip String    ${current_memory_limit.stdout}
    RW.Core.Add Pre To Report    ----------\nCurrent Memory Request: ${current_memory_value}\nCurrent Memory Limit: ${current_memory_limit_value}

    # Determine new memory values
    ${new_memory_value}=    Set Variable    ${EMPTY}
    ${new_memory_limit_value}=    Set Variable    ${EMPTY}
    ${suggestion_only}=    Set Variable    ${FALSE}

    IF    $is_gitops_managed == "true"
        ${suggestion_only}=    Set Variable    ${TRUE}
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Deployment `${DEPLOYMENT_NAME}` should allow automatic resource updates
        ...    actual=Deployment `${DEPLOYMENT_NAME}` is managed by GitOps and requires manual updates
        ...    title=Deployment `${DEPLOYMENT_NAME}` is GitOps-managed - Manual Update Required
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} is managed by GitOps (Flux/ArgoCD). Resource changes should be made in the Git repository.
        ...    next_steps=Update resource requests in the Git repository that manages this deployment.
        ...    observed_at=${timestamp}
    END

    IF    $hpa_exists != ""
        ${suggestion_only}=    Set Variable    ${TRUE}
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Deployment `${DEPLOYMENT_NAME}` should allow resource updates
        ...    actual=Deployment `${DEPLOYMENT_NAME}` has an HPA configured
        ...    title=Deployment `${DEPLOYMENT_NAME}` has HPA - Resource Update Not Recommended
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} has an HPA: ${hpa_exists}. Changing resources may affect HPA behavior.
        ...    next_steps=Review HPA configuration before modifying memory resources. Consider adjusting HPA thresholds instead.
        ...    observed_at=${timestamp}
    END

    IF    $current_memory_value != ""
        # Parse memory request: detect unit BEFORE stripping, convert to Mi for calculation
        # Kubernetes formats: Mi (mebibytes), Gi (gibibytes), M (megabytes), G (gigabytes), Ki, k, etc.
        ${memory_in_mi}=    Evaluate    int(float("${current_memory_value}".replace("Gi","")) * 1024) if "Gi" in "${current_memory_value}" else (int(float("${current_memory_value}".replace("G","")) * 1000) if ("G" in "${current_memory_value}" and "Gi" not in "${current_memory_value}") else (int(float("${current_memory_value}".replace("Mi",""))) if "Mi" in "${current_memory_value}" else (int(float("${current_memory_value}".replace("M",""))) if "M" in "${current_memory_value}" else int(float("${current_memory_value}".replace("Ki","")) / 1024))))
        ${new_memory_mi}=    Evaluate    max(16, int(${memory_in_mi} / ${RESOURCE_SCALE_DOWN_FACTOR}))
        ${new_memory_value}=    Set Variable    ${new_memory_mi}Mi
        
        IF    $current_memory_limit_value != ""
            ${memory_limit_in_mi}=    Evaluate    int(float("${current_memory_limit_value}".replace("Gi","")) * 1024) if "Gi" in "${current_memory_limit_value}" else (int(float("${current_memory_limit_value}".replace("G","")) * 1000) if ("G" in "${current_memory_limit_value}" and "Gi" not in "${current_memory_limit_value}") else (int(float("${current_memory_limit_value}".replace("Mi",""))) if "Mi" in "${current_memory_limit_value}" else (int(float("${current_memory_limit_value}".replace("M",""))) if "M" in "${current_memory_limit_value}" else int(float("${current_memory_limit_value}".replace("Ki","")) / 1024))))
            ${new_memory_limit_mi}=    Evaluate    max(16, int(${memory_limit_in_mi} / ${RESOURCE_SCALE_DOWN_FACTOR}))
            ${new_memory_limit_value}=    Set Variable    ${new_memory_limit_mi}Mi
        END
        
        # Report message based on whether this is suggestion-only or will be applied
        IF    $suggestion_only
            IF    $new_memory_limit_value != ""
                RW.Core.Add Pre To Report    ----------\nSuggested Memory Resources (÷${RESOURCE_SCALE_DOWN_FACTOR}):\nRequest: ${new_memory_value}\nLimit: ${new_memory_limit_value}
            ELSE
                RW.Core.Add Pre To Report    ----------\nSuggested Memory Resources (÷${RESOURCE_SCALE_DOWN_FACTOR}):\nRequest: ${new_memory_value}\nLimit: Not set
            END
        ELSE
            IF    $new_memory_limit_value != ""
                RW.Core.Add Pre To Report    ----------\nDecreasing Memory Resources:\nRequest: ${current_memory_value} → ${new_memory_value}\nLimit: ${current_memory_limit_value} → ${new_memory_limit_value}
            ELSE
                RW.Core.Add Pre To Report    ----------\nDecreasing Memory Resources:\nRequest: ${current_memory_value} → ${new_memory_value}\nLimit: Not currently set
            END
        END
    ELSE
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Deployment `${DEPLOYMENT_NAME}` should have memory resource requests configured
        ...    actual=Deployment `${DEPLOYMENT_NAME}` has no memory resource requests set
        ...    title=Deployment `${DEPLOYMENT_NAME}` Missing Memory Resource Requests
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} does not have memory resource requests configured.
        ...    next_steps=Cannot decrease resources - no current memory requests found\nManually configure memory resource requests for the deployment first
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Commands Used: ${history}
    END

    IF    not $suggestion_only and $new_memory_value != ""
        # Build the resource update command with both requests and limits
        ${limits_arg}=    Set Variable    ${EMPTY}
        IF    $new_memory_limit_value != ""
            ${limits_arg}=    Set Variable    ${SPACE}--limits=memory=${new_memory_limit_value}
        END
        ${patch_cmd}=    Set Variable    ${KUBERNETES_DISTRIBUTION_BINARY} set resources deployment/${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} --requests=memory=${new_memory_value}${limits_arg}
        ${resource_update}=    RW.CLI.Run Cli
        ...    cmd=${patch_cmd}
        ...    env=${env}
        ...    include_in_history=true
        ...    timeout_seconds=180
        ...    secret_file__kubeconfig=${kubeconfig}
        RW.Core.Add Pre To Report    ----------\nMemory Resource Update Applied:\n${resource_update.stdout}
        
        IF    ($resource_update.stderr) != ""
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Deployment `${DEPLOYMENT_NAME}` memory resources should update successfully
            ...    actual=Deployment `${DEPLOYMENT_NAME}` memory resource update failed
            ...    title=Failed to Decrease Memory Resources for `${DEPLOYMENT_NAME}`
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=Error updating memory resources: \n${resource_update.stderr}
            ...    next_steps=Review deployment configuration and permissions\nManually update memory resources if needed
            ...    observed_at=${timestamp}
        ELSE
            ${limit_detail}=    Set Variable If    $new_memory_limit_value != ""    \nLimit: ${current_memory_limit_value} → ${new_memory_limit_value}    \nLimit: Not currently set
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Deployment `${DEPLOYMENT_NAME}` memory resources decreased
            ...    actual=Deployment `${DEPLOYMENT_NAME}` memory resources decreased successfully
            ...    title=Memory Resources Decreased for `${DEPLOYMENT_NAME}`
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=Memory resources for deployment ${DEPLOYMENT_NAME} in namespace ${NAMESPACE} were decreased by ${RESOURCE_SCALE_DOWN_FACTOR}x.\nRequest: ${current_memory_value} → ${new_memory_value}${limit_detail}
            ...    next_steps=Monitor deployment performance for OOMKilled events\nIncrease resources if pods are being killed due to memory pressure\nReview memory usage patterns in monitoring
            ...    observed_at=${timestamp}
        END
    ELSE IF    $new_memory_value != ""
        ${limits_suggestion}=    Set Variable    ${EMPTY}
        IF    $new_memory_limit_value != ""
            ${limits_suggestion}=    Set Variable    ${SPACE}--limits=memory=${new_memory_limit_value}
        END
        RW.Core.Add Pre To Report    ----------\nSuggested Memory Resource Update (Not Applied):\nRun: ${KUBERNETES_DISTRIBUTION_BINARY} set resources deployment/${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} --requests=memory=${new_memory_value}${limits_suggestion}
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
    ${MAX_REPLICAS}=    RW.Core.Import User Variable    MAX_REPLICAS
    ...    type=string
    ...    description=The Max replicas for any scaleup activity.  
    ...    example=10
    ...    default=10
    ${ALLOW_SCALE_TO_ZERO}=    RW.Core.Import User Variable    ALLOW_SCALE_TO_ZERO
    ...    type=string
    ...    description=Permit deployments to scale to 0.   
    ...    example=false
    ...    default=false
    ${HPA_SCALE_FACTOR}=    RW.Core.Import User Variable    HPA_SCALE_FACTOR
    ...    type=string
    ...    description=The multiple by which to scale HPA min/max replicas.
    ...    example=2
    ...    default=2
    ${HPA_MAX_REPLICAS}=    RW.Core.Import User Variable    HPA_MAX_REPLICAS
    ...    type=string
    ...    description=The maximum replicas allowed for HPA max value during scale up operations.
    ...    example=20
    ...    default=20
    ${HPA_MIN_REPLICAS}=    RW.Core.Import User Variable    HPA_MIN_REPLICAS
    ...    type=string
    ...    description=The minimum replicas to set for HPA during scale down operations.
    ...    example=1
    ...    default=1
    ${RESOURCE_SCALE_DOWN_FACTOR}=    RW.Core.Import User Variable    RESOURCE_SCALE_DOWN_FACTOR
    ...    type=string
    ...    description=The factor by which to divide CPU/memory resources when scaling down (e.g., 2 means divide by 2).
    ...    example=2
    ...    default=2
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${DEPLOYMENT_NAME}    ${DEPLOYMENT_NAME}
    Set Suite Variable    ${SCALE_UP_FACTOR}    ${SCALE_UP_FACTOR}
    Set Suite Variable    ${MAX_REPLICAS}    ${MAX_REPLICAS}
    Set Suite Variable    ${ALLOW_SCALE_TO_ZERO}    ${ALLOW_SCALE_TO_ZERO}
    Set Suite Variable    ${HPA_SCALE_FACTOR}    ${HPA_SCALE_FACTOR}
    Set Suite Variable    ${HPA_MAX_REPLICAS}    ${HPA_MAX_REPLICAS}
    Set Suite Variable    ${HPA_MIN_REPLICAS}    ${HPA_MIN_REPLICAS}
    Set Suite Variable    ${RESOURCE_SCALE_DOWN_FACTOR}    ${RESOURCE_SCALE_DOWN_FACTOR}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}", "DEPLOYMENT_NAME": "${DEPLOYMENT_NAME}", "MAX_REPLICAS": "${MAX_REPLICAS}", "ALLOW_SCALE_TO_ZERO":"${ALLOW_SCALE_TO_ZERO}", "HPA_SCALE_FACTOR":"${HPA_SCALE_FACTOR}", "HPA_MAX_REPLICAS":"${HPA_MAX_REPLICAS}", "HPA_MIN_REPLICAS":"${HPA_MIN_REPLICAS}", "RESOURCE_SCALE_DOWN_FACTOR":"${RESOURCE_SCALE_DOWN_FACTOR}"}