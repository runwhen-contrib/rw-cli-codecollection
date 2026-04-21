*** Settings ***
Documentation     Measures VictoriaMetrics namespace health using pod readiness and PVC binding for discovered workloads. Produces a value between 0 (failing) and 1 (healthy).
Metadata          Author    rw-codebundle-agent
Metadata          Display Name    Kubernetes VictoriaMetrics Health Check
Metadata          Supports    Kubernetes AKS EKS GKE OpenShift VictoriaMetrics

Suite Setup       Suite Initialization
Library           BuiltIn
Library           RW.Core
Library           RW.CLI
Library             RW.platform
Library           OperatingSystem
Library           Collections


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=The Kubernetes namespace where VictoriaMetrics runs.
    ...    pattern=\w*
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    default=kubectl
    ${VM_LABEL_SELECTOR}=    RW.Core.Import User Variable    VM_LABEL_SELECTOR
    ...    type=string
    ...    description=Optional label selector to scope VictoriaMetrics pods.
    ...    pattern=.*
    ...    default=${EMPTY}
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${VM_LABEL_SELECTOR}    ${VM_LABEL_SELECTOR}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}", "VM_LABEL_SELECTOR":"${VM_LABEL_SELECTOR}"}


*** Tasks ***
Collect VictoriaMetrics SLI Metrics in Namespace `${NAMESPACE}`
    [Documentation]    Runs a lightweight kubectl+jq check for unready VM pods and unbound VM-related PVCs; emits binary sub-scores.
    [Tags]    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sli-vm-metrics.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=30
    ...    include_in_history=false
    ...    cmd_override=./sli-vm-metrics.sh

    TRY
        ${metrics}=    Evaluate    json.loads(r'''${result.stdout}''')    json
        ${rs}=    Evaluate    int($metrics['readiness_score'])
        ${ps}=    Evaluate    int($metrics['pvc_score'])
    EXCEPT
        Log    SLI JSON parse failed; scoring degraded to 0.    WARN
        ${rs}=    Set Variable    0
        ${ps}=    Set Variable    0
    END

    RW.Core.Push Metric    ${rs}    sub_name=vm_readiness
    RW.Core.Push Metric    ${ps}    sub_name=vm_pvc

    ${health_score}=    Evaluate    (float(${rs}) + float(${ps})) / 2
    ${health_score}=    Convert to Number    ${health_score}    2
    RW.Core.Add to Report    VictoriaMetrics health score: ${health_score} (readiness=${rs}, pvc=${ps})
    RW.Core.Push Metric    ${health_score}
