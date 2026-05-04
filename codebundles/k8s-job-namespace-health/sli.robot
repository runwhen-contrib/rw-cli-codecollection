*** Settings ***
Metadata          Author    rw-codebundle-agent
Documentation     Measures namespace Job and CronJob health with lightweight kubectl checks. Produces a value between 0 (failing) and 1 (healthy) from the mean of binary sub-scores.
Metadata          Display Name    Kubernetes Namespace Job Health
Metadata          Supports    Kubernetes,AKS,EKS,GKE,OpenShift
Suite Setup       Suite Initialization
Library           BuiltIn
Library           RW.Core
Library           RW.CLI
Library           RW.platform


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=Kubeconfig with list/get on jobs, cronjobs, pods, and events in the target namespace.
    ...    pattern=\w*
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Kubernetes CLI binary (kubectl or oc).
    ...    enum=[kubectl,oc]
    ...    default=kubectl
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Kubernetes context for API calls.
    ...    pattern=\w*
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=Namespace to score.
    ...    pattern=\w*
    ${JOB_ACTIVE_DURATION_WARN_MINUTES}=    RW.Core.Import User Variable    JOB_ACTIVE_DURATION_WARN_MINUTES
    ...    type=string
    ...    description=Maximum minutes an active Job may run before the SLI treats it as degraded.
    ...    pattern=^\d+$
    ...    default=360
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${JOB_ACTIVE_DURATION_WARN_MINUTES}    ${JOB_ACTIVE_DURATION_WARN_MINUTES}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}


*** Tasks ***
Score Failed Jobs Dimension for Namespace `${NAMESPACE}`
    [Documentation]    1 when no Job has a Failed=True condition; 0 otherwise.
    [Tags]    access:read-only    data:config
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get jobs -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '[.items[] | select([.status.conditions[]? | select(.type=="Failed" and .status=="True")] | length > 0)] | length'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=30
    TRY
        ${n}=    Convert To Integer    ${rsp.stdout}
        ${score_failed}=    Evaluate    1 if ${n} == 0 else 0
    EXCEPT
        Log    Failed to parse failed job count; scoring 0    WARN
        ${score_failed}=    Set Variable    0
    END
    Set Suite Variable    ${score_failed}
    RW.Core.Push Metric    ${score_failed}    sub_name=failed_jobs

Score Long-Running Active Jobs for Namespace `${NAMESPACE}`
    [Documentation]    1 when no active Job exceeds JOB_ACTIVE_DURATION_WARN_MINUTES based on status.startTime.
    [Tags]    access:read-only    data:config
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get jobs -n ${NAMESPACE} --context ${CONTEXT} -o json | jq --argjson warn ${JOB_ACTIVE_DURATION_WARN_MINUTES} -r '[.items[] | select((.status.active // 0) > 0) | select(((.status.startTime // "") | length) > 0 and (((now - (.status.startTime | fromdateiso8601)) / 60) > ($warn | tonumber)))] | length'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=30
    TRY
        ${n}=    Convert To Integer    ${rsp.stdout}
        ${score_active}=    Evaluate    1 if ${n} == 0 else 0
    EXCEPT
        Log    Failed to parse long-running job count; scoring 0    WARN
        ${score_active}=    Set Variable    0
    END
    Set Suite Variable    ${score_active}
    RW.Core.Push Metric    ${score_active}    sub_name=long_running_active

Score CronJob Reliability for Namespace `${NAMESPACE}`
    [Documentation]    1 when no CronJob is suspended and no latest CronJob-owned Job is in Failed=True state.
    [Tags]    access:read-only    data:config
    ${susp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get cronjobs -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '[.items[] | select(.spec.suspend == true)] | length'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=30
    ${failed_child}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get jobs -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '[.items[] | select([.metadata.ownerReferences[]? | select(.kind=="CronJob")] | length > 0)] | group_by([.metadata.ownerReferences[] | select(.kind=="CronJob") | .name][0]) | map(sort_by(.metadata.creationTimestamp) | last) | map(select([.status.conditions[]? | select(.type=="Failed" and .status=="True")] | length > 0)) | length'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=30
    TRY
        ${ns}=    Convert To Integer    ${susp.stdout}
        ${nf}=    Convert To Integer    ${failed_child.stdout}
        ${score_cj}=    Evaluate    1 if (${ns} == 0 and ${nf} == 0) else 0
    EXCEPT
        Log    Failed CronJob dimension parse; scoring 0    WARN
        ${score_cj}=    Set Variable    0
    END
    Set Suite Variable    ${score_cj}
    RW.Core.Push Metric    ${score_cj}    sub_name=cronjob_reliability

Generate Namespace Job Health Score
    [Documentation]    Averages sub-scores into the final 0-1 metric for alerting.
    ${health_score}=    Evaluate    (${score_failed} + ${score_active} + ${score_cj}) / 3
    ${health_score}=    Convert To Number    ${health_score}    2
    # Assign message first; `name=${...}` in the call is parsed as Add To Report named args.
    ${report_msg}=    Set Variable    Namespace Job/CronJob health score: ${health_score} (failed_jobs=${score_failed}, long_running=${score_active}, cronjob=${score_cj})
    RW.Core.Add To Report    ${report_msg}
    RW.Core.Push Metric    ${health_score}
