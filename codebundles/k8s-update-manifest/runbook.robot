*** Settings ***
Documentation       Creates a PR on the repository file for the manifest object with the suggested change(s)
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes Manifest Update
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.K8sApplications
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Scale Up `${WORKLOAD_NAME}` HorizontalPodAutoscaler
    [Documentation]    Creates a PR against a manifest file in a repo with a suggested replica count change.
    [Tags]
    ...    gitops
    ...    change request
    ...    replicas
    ...    horizontalpodautoscaler
    ...    scaling
    ...    increase
    ...    pods
    ...    containers
    ...    resources
    ${infra_repo}=    RW.K8sApplications.Clone Repo    ${REPO_URI}    ${REPO_AUTH_TOKEN}    1
    ${report}=    RW.K8sApplications.Scale Up Hpa
    ...    infra_repo=${infra_repo}
    ...    manifest_file_path=${REPO_MANIFEST_PATH}
    ...    increase_value=1
    ...    max_allowed_replicas=${REPLICA_MAX}
    RW.Core.Add Pre To Report    ${report}


*** Keywords ***
Suite Initialization
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
    ${REPO_MANIFEST_PATH}=    RW.Core.Import User Variable
    ...    REPO_MANIFEST_PATH
    ...    type=string
    ...    description=The path to the manifest file to update.
    ...    pattern=\w*
    ...    example=apps/backend-services/my-app-deployment.yaml
    ${WORKLOAD_NAME}=    RW.Core.Import User Variable
    ...    WORKLOAD_NAME
    ...    type=string
    ...    description=The name of the workload, used for search quality.
    ...    pattern=\w*
    ...    example=deployment.apps/my-app
    ${INCREASE_AMOUNT}=    RW.Core.Import User Variable
    ...    INCREASE_AMOUNT
    ...    type=string
    ...    description=The amount of replicas to increase the HPA spec by.
    ...    pattern=\w*
    ...    example=1
    ...    default=1
    ${REPLICA_MAX}=    RW.Core.Import User Variable
    ...    REPLICA_MAX
    ...    type=string
    ...    description=The maximum allowed replicas.
    ...    pattern=\w*
    ...    example=10
    ...    default=10
    Set Suite Variable    ${REPO_URI}    ${REPO_URI}
    Set Suite Variable    ${REPO_AUTH_TOKEN}    ${REPO_AUTH_TOKEN}
    Set Suite Variable    ${WORKLOAD_NAME}    ${WORKLOAD_NAME}
    Set Suite Variable    ${REPO_MANIFEST_PATH}    ${REPO_MANIFEST_PATH}
    Set Suite Variable    ${INCREASE_AMOUNT}    ${INCREASE_AMOUNT}
    Set Suite Variable    ${REPLICA_MAX}    ${REPLICA_MAX}
