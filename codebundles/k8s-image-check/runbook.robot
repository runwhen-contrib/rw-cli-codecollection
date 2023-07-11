*** Settings ***
Documentation       This taskset provides detailed information about the images used in a Kubernetes namespace.
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes Image Check
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             DateTime
Library             Collections

Suite Setup         Suite Initialization


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
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}

*** Tasks ***
Check Image Rollover Times In Namespace
    [Documentation]    Fetches and checks when images last rolled over in a namespace.
    [Tags]    Pods    Containers    Image    Images    Source    Age    Pulled    Time    Application    Restarts    Not starting    Failed    Rollout
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} --field-selector=status.phase==Running -o json | jq -r '[.items[] | "Images: " + (.spec.containers[].image|tostring) + ", Last Started Times:" + (.status.containerStatuses[].state.running.startedAt|tostring)]'
    ...    render_in_commandlist=true
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    Image Info:\n${rsp.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}
List Images and Tags for Every Container in Running Pods
    [Documentation]    Display the status, image name, image tag, and container name for running pods in the namespace. 
    [Tags]    Pods    Containers    Image    Images    Tag
    ${image_details}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} --field-selector=status.phase==Running -o=json | jq -r '.items[] | "---", "pod_name: " + .metadata.name, "Status: " + .status.phase, "containers:", (.spec.containers[] | "- container_name: " + .name, " \ image_path: " + (.image | split(":")[0]), " \ image_tag: " + (.image | split(":")[1])), "---"'
    ...    render_in_commandlist=true
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    Image details for pods in ${NAMESPACE}:\n${image_details.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

List Images and Tags for Every Container in Failed Pods
    [Documentation]    Display the status, image name, image tag, and container name for failed pods in the namespace. 
    [Tags]    Pods    Containers    Image    Images    Tag
    ${image_details}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} --field-selector=status.phase==Failed -o=json | jq -r '.items[] | "---", "pod_name: " + .metadata.name, "Status: " + .status.phase, "containers:", (.spec.containers[] | "- container_name: " + .name, " \ image_path: " + \(.image | split(":")[0]), " \ image_tag: " + (.image | split(":")[1])), "---"'
    ...    render_in_commandlist=true
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    Image details for pods in ${NAMESPACE}:\n${image_details.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}
