*** Settings ***
Documentation       This codebundle runs a series of tasks to identify potential helm release issues related to Flux managed Helm objects. 
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes FluxCD HelmRelease TaskSet
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift,FluxCD
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.K8sHelper

Suite Setup         Suite Initialization


*** Tasks ***
List all available FluxCD Helmreleases in Namespace `${NAMESPACE}`     
    [Documentation]    List all FluxCD helmreleases that are visible to the kubeconfig.    
    [Tags]        FluxCD     Helmrelease     Available    List    ${NAMESPACE}    data:config
    ${helmreleases}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get ${RESOURCE_NAME} -n ${NAMESPACE} --context ${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Helmreleases available: \n ${helmreleases.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Fetch Installed FluxCD Helmrelease Versions in Namespace `${NAMESPACE}`   
    [Documentation]    List helmreleases and  the last attempted software version and the current running version.  
    [Tags]        FluxCD     Helmrelease    Versions    ${NAMESPACE}    data:config
    ${helmrelease_versions}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get ${RESOURCE_NAME} -n ${NAMESPACE} -o=jsonpath="{range .items[*]}{'\\nName: '}{@.metadata.name}{'\\nlastAppliedRevision:'}{@.status.lastAppliedRevision}{'\\nlastAttemptedRevision:'}{@.status.lastAttemptedRevision}{'\\n---'}{end}" --context ${CONTEXT} || true
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Helmreleases status errors: \n ${helmrelease_versions.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Fetch Mismatched FluxCD HelmRelease Version in Namespace `${NAMESPACE}` 
    [Documentation]    List helmreleases and use jq to display any releases where the last attempted software revision doesn't match the current running revision. Requires jq.  
    [Tags]        FluxCD     Helmrelease    Version    Mismatched    Unhealthy    ${NAMESPACE}    data:config
    ${helmrelease_version_mismatches}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get ${RESOURCE_NAME} -n ${NAMESPACE} -o json --context ${CONTEXT} | jq -r '.items[] | select(.status.lastAppliedRevision!=.status.lastAttemptedRevision) | "Name: " + .metadata.name + " Last Attempted Version: " + .status.lastAttemptedRevision + " Last Applied Revision: " + .status.lastAppliedRevision'
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${regexp}=    Catenate
    ...    (?m)(?P<line>.+)
    # Check if any HelmRelease version mismatches are found
    ${contains_name}=    Run Keyword And Return Status    Should Contain    ${helmrelease_version_mismatches.stdout}    Name
    IF    ${contains_name}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Flux HelmRelease lastApplied and lastAttempted Revision should match
        ...    actual=Flux HelmRelease lastApplied and lastAttempted Revision do not match
        ...    title=FluxCD HelmRelease Version Mismatch in Namespace `${NAMESPACE}`
        ...    details=The currently applied helm release does not match the attemped installation version: ${helmrelease_version_mismatches.stdout}
        ...    reproduce_hint=Check FluxCD HelmRelease status and reconciliation
        ...    next_steps=Fetch FluxCD HelmRelease Error Messages in Namespace `${NAMESPACE}`
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Helmreleases version mismatches: \n ${helmrelease_version_mismatches.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Fetch FluxCD HelmRelease Error Messages in Namespace `${NAMESPACE}`     
    [Documentation]    List helmreleases and display the status conditions message for any helmreleases that are not in a Ready state. 
    [Tags]        FluxCD     Helmrelease    Errors     Unhealthy    Message    ${NAMESPACE}    data:config
    ${helmrelease_errors}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get ${RESOURCE_NAME} -n ${NAMESPACE} -o=jsonpath="{range .items[*]}[?(@.status.conditions[?(@.type=='Ready')].status=='False')]{'-----\\nName: '}{@.metadata.name}--{@.status.conditions[0].lastTransitionTime}{'\\n'}{@.status.conditions[*].message}{'\\n'}{'Observed At: '}{@.status.conditions[-1].lastTransitionTime}{'\\n'}{end}" --context ${CONTEXT} || true
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
   ${regexp}=    Catenate
    ...    (?m)(?P<line>.+)
    # Check if any HelmRelease errors are found
    ${contains_name_error}=    Run Keyword And Return Status    Should Contain    ${helmrelease_errors.stdout}    Name
    IF    ${contains_name_error}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Flux HelmRelease Objects should be in a ready state
        ...    actual=Flux HelmRelease Objects are not in a ready state
        ...    title=FluxCD HelmRelease Errors in Namespace `${NAMESPACE}`
        ...    details=FluxCD helm releases are found to be in an errored state: ${helmrelease_errors.stdout}
        ...    reproduce_hint=Check FluxCD HelmRelease status and error conditions
        ...    next_steps=Escalate HelmRelease error messages to service owner.
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Helmreleases status errors: \n ${helmrelease_errors.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Check for Available Helm Chart Updates in Namespace `${NAMESPACE}`     
    [Documentation]    List all helmreleases in namespace and check for available helmchart updates. 
    [Tags]        FluxCD     Helmchart    Errors     Unhealthy    Message   HelmRelease    ${NAMESPACE}    data:config
    ${helmchart_updates_available}=    RW.CLI.Run Cli
    ...    cmd=namespace="${NAMESPACE}" context="${CONTEXT}"; helm_releases=$(${KUBERNETES_DISTRIBUTION_BINARY} get ${RESOURCE_NAME} -n "$namespace" --context "$context" -o json | jq -r '.items[] | .metadata.name'); echo "$helm_releases" | while IFS= read -r release; do chart_details=$(${KUBERNETES_DISTRIBUTION_BINARY} get ${RESOURCE_NAME} "$release" -n "$namespace" --context "$context" -o json | jq -r '.spec.chart.spec // empty'); if [[ -n "$chart_details" ]]; then chart_kind=$(echo "$chart_details" | jq -r '.sourceRef.kind // empty'); chart_name=$(echo "$chart_details" | jq -r '.chart // empty'); chart_source_name=$(echo "$chart_details" | jq -r '.sourceRef.name // empty'); chart_namespace=$(echo "$chart_details" | jq -r '.sourceRef.namespace // empty'); chart_version=$(echo "$chart_details" | jq -r '.version // "N/A"'); if [[ "$chart_kind" == "HelmRepository" && -n "$chart_name" && -n "$chart_namespace" ]]; then repo_url=$(${KUBERNETES_DISTRIBUTION_BINARY} get helmrepositories.source.toolkit.fluxcd.io "$chart_source_name" -n "$chart_namespace" --context "$context" -o json | jq -r '.spec.url // empty'); if [[ -n "$repo_url" ]]; then temp_repo_name="$chart_source_name-temp-$release"; add_repo=$(helm repo add "$temp_repo_name" "$repo_url"); available_chart_version=$(helm search repo "$temp_repo_name"/"$chart_name" --version ">$chart_version" --output json | jq -r '.[].version'); if [[ -n "$available_chart_version" ]]; then sorted_versions=($(echo "\${available_chart_version[@]}" | tr ' ' '\\n' | sort -V)); available_version=\${sorted_versions[-1]}; version_update_available="True"; else available_version="N/A"; version_update_available="False"; fi; remove_repo=$(helm repo remove "$temp_repo_name"); else available_version="N/A"; version_update_available="False"; fi; else available_version="N/A"; version_update_available="False"; fi; else chart_name="N/A"; chart_namespace="N/A"; chart_version="N/A"; available_version="N/A"; version_update_available="False"; fi; echo "Release: $release | Chart: $chart_namespace/$chart_name | Installed Version: $chart_version | Available Update: $version_update_available | Available Version: $available_version"; done
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    HelmChart Version Update Details: \n ${helmchart_updates_available.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${DISTRIBUTION}=    RW.Core.Import User Variable    DISTRIBUTION
    ...    type=string
    ...    description=Which distribution of Kubernetes to use for operations, such as: Kubernetes, OpenShift, etc.
    ...    pattern=\w*
    ...    enum=[Kubernetes,GKE,OpenShift]
    ...    example=Kubernetes
    ...    default=Kubernetes
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=The name of the Kubernetes namespace to scope actions and searching to. Accepts a single namespace in the format `-n namespace-name` or `--all-namespaces`. 
    ...    pattern=\w*
    ...    example=-n my-namespace
    ...    default=--all-namespaces
    ${RESOURCE_NAME}=    RW.Core.Import User Variable    RESOURCE_NAME
    ...    type=string
    ...    description=The short or long name of the Kubernetes helmrelease resource to search for. These might vary by helm controller implementation, and are best to use full crd name. 
    ...    pattern=\w*
    ...    example=helmreleases.helm.toolkit.fluxcd.io
    ...    default=helmreleases
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    default=default
    ...    example=my-main-cluster
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${RESOURCE_NAME}    ${RESOURCE_NAME}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}

    # Verify cluster connectivity
    RW.K8sHelper.Verify Cluster Connectivity
    ...    binary=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    context=${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}

