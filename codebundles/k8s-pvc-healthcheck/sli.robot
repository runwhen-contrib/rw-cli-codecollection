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
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}"}



*** Tasks ***
Fetch the Storage Utilization for PVC Mounts in Namespace `${NAMESPACE}`
    [Documentation]    For each pod in a namespace, fetch the utilization of any PersistentVolumeClaims mounted using the linux df command. Requires kubectl exec permissions.
    [Tags]    pod    storage    pvc    utilization    capacity    persistentvolumeclaims    persistentvolumeclaim    check pvc    ${NAMESPACE}    data:config
    ${pvc_utilization_script}=    RW.CLI.Run Bash File
    ...    bash_file=pvc_utilization_check.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${pvc_recommendations}=    RW.CLI.Run Cli
    ...    cmd=cat pvc_issues.json
    ...    env=${env}
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${pvc_recommendations.stdout}''')    json
    ${pvc_utilization_score}=    Evaluate    1 if len(@{issue_list}) == 0 else 0
    Set Global Variable    ${pvc_utilization_score}

Generate Namespace Score for Namespace `${NAMESPACE}`
    ${pvc_health_score}=      Evaluate  (${pvc_utilization_score}) / 1
    ${health_score}=      Convert to Number    ${pvc_health_score}  2
    RW.Core.Push Metric    ${health_score}    sub_name=pvc_health
    RW.Core.Push Metric    ${health_score}