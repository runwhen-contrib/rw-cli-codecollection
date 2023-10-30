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


*** Tasks ***
Check Image Rollover Times In Namespace
    [Documentation]    Fetches and checks when images last rolled over in a namespace.
    [Tags]
    ...    pods
    ...    containers
    ...    image
    ...    images
    ...    source
    ...    age
    ...    pulled
    ...    time
    ...    application
    ...    restarts
    ...    not starting
    ...    failed
    ...    rollout
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} --field-selector=status.phase==Running -o json | jq -r '[.items[] | "Images: " + (.spec.containers[].image|tostring) + ", Last Started Times:" + (.status.containerStatuses[].state.running.startedAt|tostring)]'
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    Image Info:\n${rsp.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

List Images and Tags for Every Container in Running Pods
    [Documentation]    Display the status, image name, image tag, and container name for running pods in the namespace.
    [Tags]    pods    containers    image    images    tag
    ${image_details}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} --field-selector=status.phase==Running -o=json | jq -r '.items[] | "---", "pod_name: " + .metadata.name, "Status: " + .status.phase, "containers:", (.spec.containers[] | "- container_name: " + .name, " \ image_path: " + (.image | split(":")[0]), " \ image_tag: " + (.image | split(":")[1])), "---"'
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    Image details for pods in ${NAMESPACE}:\n${image_details.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

List Images and Tags for Every Container in Failed Pods
    [Documentation]    Display the status, image name, image tag, and container name for failed pods in the namespace.
    [Tags]    pods    containers    image    images    tag
    ${image_details}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} --field-selector=status.phase==Failed -o=json | jq -r '.items[] | "---", "pod_name: " + .metadata.name, "Status: " + .status.phase, "containers:", (.spec.containers[] | "- container_name: " + .name, " \ image_path: " + \(.image | split(":")[0]), " \ image_tag: " + (.image | split(":")[1])), "---"'
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    Image details for pods in ${NAMESPACE}:\n${image_details.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

List ImagePullBackOff Events and Test Path and Tags
    [Documentation]    Search events in the last 5 minutes for BackOff events related to image pull issues. Run Skopeo to test if the image path exists and what tags are available.
    [Tags]    containers    image    images    tag    imagepullbackoff    skopeo    backoff
    ${image_path_and_tag_details}=    RW.CLI.Run Cli
    ...    cmd=NAMESPACE=${NAMESPACE}; POD_NAME="skopeo-pod"; CONTEXT="${CONTEXT}"; events=$(${KUBERNETES_DISTRIBUTION_BINARY} get events -n $NAMESPACE --context=$CONTEXT -o json | jq --arg timestamp "$(date -u -v -5M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "-5 minutes" +"%Y-%m-%dT%H:%M:%SZ")" '.items[] | select(.lastTimestamp > $timestamp)'); if [[ ! -z "\${events-unset}" ]]; then image_pull_backoff_events=$(echo "$events" | jq -s '[.[] | select(.reason == "BackOff") | .message] | .[]'); else echo "No events found in the last 5 minutes"; exit; fi; if [[ $image_pull_backoff_events =~ "Back-off pulling image" ]]; then echo "Running Skopeo Pod"; ${KUBERNETES_DISTRIBUTION_BINARY} run $POD_NAME --restart=Never -n $NAMESPACE --context=$CONTEXT --image=quay.io/containers/skopeo:latest --command -- sleep infinity && echo "Waiting for the $POD_NAME to be running..." && ${KUBERNETES_DISTRIBUTION_BINARY} wait --for=condition=Ready pod/$POD_NAME -n $NAMESPACE --context=$CONTEXT; else echo "No image pull backoff events found"; exit; fi; while IFS= read -r event; do echo "Found BackOff with message: $event"; echo "Checking if we can reach the image with skopeo and what tags exist"; container_image_path_tag=$(echo "$event" | cut -d' ' -f4 | tr -d '"' | tr -d '\\'); container_image_path="\${container_image_path_tag%:*}"; container_image_tag="\${container_image_path_tag#*:}"; if [ -z "$container_image_path" ] || [ -z "$container_image_tag" ]; then continue; fi; skopeo_output=$(${KUBERNETES_DISTRIBUTION_BINARY} exec $POD_NAME -n $NAMESPACE --context=$CONTEXT -- skopeo inspect docker://$container_image_path:$container_image_tag); skopeo_exit_code=$?; if [ $skopeo_exit_code -eq 0 ]; then echo "Container image '$container_image_path:$container_image_tag' exists."; else echo "Container image '$container_image_path:$container_image_tag' does not exist."; echo "Available tags for '$container_image_path':"; available_tags=$(${KUBERNETES_DISTRIBUTION_BINARY} exec $POD_NAME -n $NAMESPACE --context=$CONTEXT -- skopeo list-tags docker://$container_image_path ); echo "$available_tags"; fi; done <<<"$image_pull_backoff_events" && echo "Deleting Skopeo pod" && ${KUBERNETES_DISTRIBUTION_BINARY} delete pod $POD_NAME -n $NAMESPACE --context=$CONTEXT && echo "Done"
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    Image details for pods in ${NAMESPACE}:\n${image_path_and_tag_details.stdout}
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
