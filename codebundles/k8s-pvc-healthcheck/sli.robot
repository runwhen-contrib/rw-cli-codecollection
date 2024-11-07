*** Settings ***
Documentation       This SLI collects information about storage such as PersistentVolumes and PersistentVolumeClaims and generates an aggregated health score for the namespace. 1 = Healthy, 0 = Failed, >0 <1 = Degraded
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes Persistent Volume Healthcheck
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             DateTime
Library             Collections
Library             String

Suite Setup         Suite Initialization


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=The name of the namespace to search.
    ...    pattern=\w*
    ...    example=otel-demo
    ...    default=
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
    Set Suite Variable    ${HOME}    ${HOME}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}", "HOME":"${HOME}"}


*** Tasks ***
Fetch the Storage Utilization for PVC Mounts in Namespace `${NAMESPACE}`
    [Documentation]    For each pod in a namespace, fetch the utilization of any PersistentVolumeClaims mounted using the linux df command. Requires kubectl exec permissions.
    [Tags]    pod    storage    pvc    utilization    capacity    persistentvolumeclaims    persistentvolumeclaim    check pvc    ${NAMESPACE}
    ${pvc_utilization_script}=    RW.CLI.Run Bash File
    ...    bash_file=pvc_utilization_check.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${pvc_recommendations}=    RW.CLI.Run Cli
    ...    cmd=echo '${pvc_utilization_script.stdout}' | awk '/Recommended Next Steps:/ {flag=1; next} flag'
    ...    env=${env}
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${pvc_recommendations.stdout}''')    json
    # IF    $pvc_recommendations.stdout != ""
    #     ${pvc_recommendation_list}=    Evaluate    json.loads(r'''${pvc_recommendations.stdout}''')    json
    #     IF    len(@{pvc_recommendation_list}) > 0
    #         FOR    ${item}    IN    @{pvc_recommendation_list}
    #             RW.Core.Add Issue
    #             ...    severity=${item["severity"]}
    #             ...    expected=PVCs are healthy and have free space in Namespace `${NAMESPACE}`
    #             ...    actual=PVC issues exist in Namespace `${NAMESPACE}`
    #             ...    title=${item["title"]} in `${NAMESPACE}`
    #             ...    reproduce_hint=${pod_pvc_utilization.cmd}
    #             ...    details=${item}
    #             ...    next_steps=${item["next_steps"]}
    #         END
    #     END
    # END    
    # Log    ${unreadypods_results.stdout} total unready pods
    ${pvc_utilization_score}=    Evaluate    1 if len(@{issue_list}) == 0 else 0
    Set Global Variable    ${pvc_utilization_score}

Generate Namspace Score
    ${pvc_health_score}=      Evaluate  (${pvc_utilization_score}) / 1
    ${health_score}=      Convert to Number    ${pvc_health_score}  2
    RW.Core.Push Metric    ${health_score}