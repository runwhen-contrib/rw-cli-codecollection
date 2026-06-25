*** Settings ***
Documentation       Measures SeaweedFS storage health using workload readiness, master leadership, volume slot availability, and filer connectivity. Produces a value between 0 (failing) and 1 (healthy).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Kubernetes SeaweedFS Storage Health Check
Metadata            Supports    Kubernetes SeaweedFS storage health S3

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             Collections

Suite Setup         Suite Initialization


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=Kubernetes kubeconfig for cluster access.
    ...    pattern=\w*
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Kubernetes CLI binary (kubectl or oc).
    ...    enum=[kubectl,oc]
    ...    default=kubectl
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Kubernetes context for the target cluster.
    ...    pattern=\w*
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=Namespace where SeaweedFS is deployed.
    ...    pattern=\w*
    ${SEAWEEDFS_RELEASE_NAME}=    RW.Core.Import User Variable    SEAWEEDFS_RELEASE_NAME
    ...    type=string
    ...    description=Helm release name override for discovery.
    ...    default=
    ...    pattern=.*
    ${MIN_FREE_VOLUME_SLOTS}=    RW.Core.Import User Variable    MIN_FREE_VOLUME_SLOTS
    ...    type=string
    ...    description=Minimum free volume slots required for a passing slots score.
    ...    default=1
    ...    pattern=^\d+$
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${SEAWEEDFS_RELEASE_NAME}    ${SEAWEEDFS_RELEASE_NAME}
    Set Suite Variable    ${MIN_FREE_VOLUME_SLOTS}    ${MIN_FREE_VOLUME_SLOTS}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}","CONTEXT":"${CONTEXT}","NAMESPACE":"${NAMESPACE}","KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}","SEAWEEDFS_RELEASE_NAME":"${SEAWEEDFS_RELEASE_NAME}","MIN_FREE_VOLUME_SLOTS":"${MIN_FREE_VOLUME_SLOTS}"}


*** Tasks ***
Score SeaweedFS Health Dimensions in Namespace `${NAMESPACE}`
    [Documentation]    Runs a compact probe returning binary scores for workload, master, slots, and connectivity dimensions.
    [Tags]    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sli-seaweedfs-dimensions.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ...    cmd_override=./sli-seaweedfs-dimensions.sh

    TRY
        ${dims}=    Evaluate    json.loads(r'''${result.stdout}''')    json
        ${workload}=    Get From Dictionary    ${dims}    workload
        ${master}=    Get From Dictionary    ${dims}    master
        ${slots}=    Get From Dictionary    ${dims}    slots
        ${connectivity}=    Get From Dictionary    ${dims}    connectivity
        ${workload}=    Convert To Integer    ${workload}
        ${master}=    Convert To Integer    ${master}
        ${slots}=    Convert To Integer    ${slots}
        ${connectivity}=    Convert To Integer    ${connectivity}
    EXCEPT
        Log    SLI dimension JSON parse failed; reporting zero health.    WARN
        ${workload}=    Convert To Integer    0
        ${master}=    Convert To Integer    0
        ${slots}=    Convert To Integer    0
        ${connectivity}=    Convert To Integer    0
    END

    RW.Core.Push Metric    ${workload}    sub_name=workload
    RW.Core.Push Metric    ${master}    sub_name=master
    RW.Core.Push Metric    ${slots}    sub_name=volume_slots
    RW.Core.Push Metric    ${connectivity}    sub_name=connectivity

    ${health_score}=    Evaluate    (${workload} + ${master} + ${slots} + ${connectivity}) / 4.0
    ${health_score}=    Convert to Number    ${health_score}    2
    RW.Core.Add to Report    Health Score: ${health_score} (workload=${workload}, master=${master}, slots=${slots}, connectivity=${connectivity})
    RW.Core.Push Metric    ${health_score}
