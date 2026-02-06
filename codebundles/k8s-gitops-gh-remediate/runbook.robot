*** Settings ***
Documentation       Provides a list of tasks that can remediate configuraiton issues with manifests in GitHub based GitOps repositories.
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes GitOps GitHub Remediation
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift,FluxCD,ArgoCD,GitHub

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.NextSteps
Library             OperatingSystem
Library             String

Suite Setup         Suite Initialization


*** Tasks ***
Remediate Readiness and Liveness Probe GitOps Manifests in Namespace `${NAMESPACE}`
    [Documentation]    Fixes misconfigured readiness or liveness probe configurations for pods in a namespace that are managed in a GitHub GitOps repository
    [Tags]    access:read-write  readiness    liveness    probe    remediate    gitops    github
    ${probe_health}=    RW.CLI.Run Bash File
    ...    bash_file=validate_all_probes.sh
    ...    cmd_override=./validate_all_probes.sh ${NAMESPACE}
    ...    env=${env}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ${remediation_list}=    RW.CLI.Run Cli
    ...    cmd=awk "/Remediation Steps:/ {start=1; getline} start" <<< '''${probe_health.stdout}'''
    ...    env=${env}
    ...    include_in_history=false
    ${gh_updates}=    RW.CLI.Run Bash File
    ...    bash_file=update_github_manifests.sh
    ...    cmd_override=./update_github_manifests.sh '${remediation_list.stdout}'
    ...    env=${env}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    secret_file__GITHUB_TOKEN=${github_token}
    ${recommendations}=    RW.CLI.Run Cli
    ...    cmd=echo '${gh_updates.stdout}' | awk '/Recommended Next Steps:/ {flag=1; next} flag'
    ...    env=${env}
    ...    include_in_history=false
    ${timestamp}=    RW.CLI.Run Cli
    ...    cmd=echo '${gh_updates.stdout}' | awk '/Observed At:/ {print $3}'
    ...    env=${env}
    ...    include_in_history=false
    IF    len($recommendations.stdout) > 0
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Pull Requests for manifest changes are reviewed for namespace `${NAMESPACE}`
        ...    actual=Pull Requests for manifest changes are open and in need of review for namespace `${NAMESPACE}`
        ...    title=Pull Requests for manifest changes are open and in need of review for namespace `${NAMESPACE}`
        ...    reproduce_hint=Check Pull Request details for more information.
        ...    details=${remediation_list.stdout}
        ...    next_steps=${recommendations.stdout}
        ...    observed_at=${timestamp.stdout}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Readiness probe testing results:\n\n${probe_health.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${probe_health.cmd}

Increase ResourceQuota Limit for Namespace `${NAMESPACE}` in GitHub GitOps Repository
    [Documentation]    Looks for a resourcequota object in the namespace and increases it if applicable, and if it is managed in a GitHub GitOps repository
    [Tags]    access:read-write  resourcequota    quota    namespace    remediate    github    gitops
    ${quota_usage}=    RW.CLI.Run Bash File
    ...    bash_file=resource_quota_check.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${quota_recommendations}=    RW.CLI.Run Cli
    ...    cmd=echo '${quota_usage.stdout}' | awk '/Recommended Next Steps:/ {flag=1; next} flag'
    ...    env=${env}
    ...    include_in_history=false
    IF    $quota_recommendations.stdout != ""
        ${quota_recommendation_list}=    Evaluate    json.loads(r'''${quota_recommendations.stdout}''')    json
        IF    len(@{quota_recommendation_list}) > 0
            ${gh_updates}=    RW.CLI.Run Bash File
            ...    bash_file=update_github_manifests.sh
            ...    cmd_override=./update_github_manifests.sh '${quota_recommendations.stdout}'
            ...    env=${env}
            ...    include_in_history=False
            ...    secret_file__kubeconfig=${kubeconfig}
            ...    secret_file__GITHUB_TOKEN=${github_token}
            ${recommendations}=    RW.CLI.Run Cli
            ...    cmd=echo '${gh_updates.stdout}' | awk '/Recommended Next Steps:/ {flag=1; next} flag'
            ...    env=${env}
            ...    include_in_history=false
            ${timestamp}=    RW.CLI.Run Cli
            ...    cmd=echo '${gh_updates.stdout}' | awk '/Observed At:/ {print $3}'
            ...    env=${env}
            ...    include_in_history=false
            IF    len($recommendations.stdout) > 0
                RW.Core.Add Issue
                ...    severity=3
                ...    expected=Pull Requests for manifest changes are reviewed for namespace `${NAMESPACE}`
                ...    actual=Pull Requests for manifest changes are open and in need of review for namespace `${NAMESPACE}`
                ...    title=Pull Requests for manifest changes are open and in need of review for namespace `${NAMESPACE}`
                ...    reproduce_hint=Check Pull Request details for more information.
                ...    details=${quota_recommendations.stdout}
                ...    next_steps=${recommendations.stdout}
                ...    observed_at=${timestamp.stdout}
            END
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${quota_usage.stdout}\n
    RW.Core.Add Pre To Report    Commands Used: ${quota_usage.cmd}

Adjust Pod Resources to Match VPA Recommendation in `${NAMESPACE}`
    [Documentation]    Queries the namespace for any Vertical Pod Autoscaler resource recommendations and applies them to GitOps GitHub controlled manifests. 
    [Tags]    access:read-write  recommendation    resources    utilization    gitops    github    pods    cpu    memory    allocation   vpa
    ${vpa_usage}=    RW.CLI.Run Bash File
    ...    bash_file=vpa_recommendations.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${vpa_recommendations}=    RW.CLI.Run Cli
    ...    cmd=echo '${vpa_usage.stdout}' | awk '/Recommended Next Steps:/ {flag=1; next} flag'
    ...    env=${env}
    ...    include_in_history=false
    IF    $vpa_recommendations.stdout != ""
        ${vpa_recommendation_list}=    Evaluate    json.loads(r'''${vpa_recommendations.stdout}''')    json
        IF    len(@{vpa_recommendation_list}) > 0
            ${gh_updates}=    RW.CLI.Run Bash File
            ...    bash_file=update_github_manifests.sh
            ...    cmd_override=./update_github_manifests.sh '${vpa_recommendations.stdout}'
            ...    env=${env}
            ...    include_in_history=False
            ...    secret_file__kubeconfig=${kubeconfig}
            ...    secret_file__token=${github_token}
            ${recommendations}=    RW.CLI.Run Cli
            ...    cmd=echo '${gh_updates.stdout}' | awk '/Recommended Next Steps:/ {flag=1; next} flag'
            ...    env=${env}
            ...    include_in_history=false
            ${timestamp}=    RW.CLI.Run Cli
            ...    cmd=echo '${gh_updates.stdout}' | awk '/Observed At:/ {print $3}'
            ...    env=${env}
            ...    include_in_history=false
            IF    len($recommendations.stdout) > 0
                RW.Core.Add Issue
                ...    severity=3
                ...    expected=Pull Requests for manifest changes are reviewed for namespace `${NAMESPACE}`
                ...    actual=Pull Requests for manifest changes are open and in need of review for namespace `${NAMESPACE}`
                ...    title=Pull Requests for manifest changes are open and in need of review for namespace `${NAMESPACE}`
                ...    reproduce_hint=Check Pull Request details for more information.
                ...    details=${vpa_recommendations.stdout}
                ...    next_steps=${recommendations.stdout}
                ...    observed_at=${timestamp.stdout}
            END
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${vpa_usage.stdout}\n
    RW.Core.Add Pre To Report    Commands Used: ${vpa_usage.cmd}

Expand Persistent Volume Claims in Namespace `${NAMESPACE}`
    [Documentation]    Checks the disk utilization for all PVCs and updates the GitOps manifest for any that are highly utilized. 
    [Tags]    access:read-write  recommendation    pv    pvc    utilization    gitops    github    persistentvolumeclaim    persistentvolume    storage    capacity
    ${pvc_utilization}=    RW.CLI.Run Bash File
    ...    bash_file=pvc_utilization_check.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${pvc_recommendations}=    RW.CLI.Run Cli
    ...    cmd=echo '${pvc_utilization.stdout}' | awk '/Recommended Next Steps:/ {flag=1; next} flag'
    ...    env=${env}
    ...    include_in_history=false
    IF    $pvc_recommendations.stdout != ""
        ${pvc_recommendation_list}=    Evaluate    json.loads(r'''${pvc_recommendations.stdout}''')    json
        IF    len(@{pvc_recommendation_list}) > 0
            ${gh_updates}=    RW.CLI.Run Bash File
            ...    bash_file=update_github_manifests.sh
            ...    cmd_override=./update_github_manifests.sh '${pvc_recommendations.stdout}'
            ...    env=${env}
            ...    include_in_history=False
            ...    secret_file__kubeconfig=${kubeconfig}
            ...    secret_file__GITHUB_TOKEN=${github_token}
            ${recommendations}=    RW.CLI.Run Cli
            ...    cmd=echo '${gh_updates.stdout}' | awk '/Recommended Next Steps:/ {flag=1; next} flag'
            ...    env=${env}
            ...    include_in_history=false
            ${timestamp}=    RW.CLI.Run Cli
            ...    cmd=echo '${gh_updates.stdout}' | awk '/Observed At:/ {print $3}'
            ...    env=${env}
            ...    include_in_history=false
            IF    len($recommendations.stdout) > 0
                RW.Core.Add Issue
                ...    severity=3
                ...    expected=Pull Requests for manifest changes are reviewed for namespace `${NAMESPACE}`
                ...    actual=Pull Requests for manifest changes are open and in need of review for namespace `${NAMESPACE}`
                ...    title=Pull Requests for manifest changes are open and in need of review for namespace `${NAMESPACE}`
                ...    reproduce_hint=Check Pull Request details for more information.
                ...    details=${pvc_recommendations.stdout}
                ...    next_steps=${recommendations.stdout}
                ...    observed_at=${timestamp.stdout}
            END
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${pvc_utilization.stdout}\n
    RW.Core.Add Pre To Report    Commands Used: ${pvc_utilization.cmd}

*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${github_token}=    RW.Core.Import Secret
    ...    github_token
    ...    type=string
    ...    description=The GitHub Personal Access token used to create commits and open PRs against the GitOps repo.
    ...    pattern=\w*
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
    ...    default=''
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    ${RW_TASK_TITLES}=    Get Environment Variable    RW_TASK_TITLES    "[]"
    ${RW_TASK_STRING}=    Evaluate    ${RW_TASK_TITLES}    json
    ${RW_TASK_STRING}=    Evaluate    ', '.join(${RW_TASK_STRING})    json
    ${RW_FRONTEND_URL}=    Get Environment Variable    RW_FRONTEND_URL    none
    ${RW_SESSION_ID}=    Get Environment Variable    RW_SESSION_ID    none
    ${RW_USERNAME}=    Get Environment Variable    RW_USERNAME    none
    ${RW_WORKSPACE}=    Get Environment Variable    RW_WORKSPACE    none

    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}", "RW_TASK_TITLES":"${RW_TASK_STRING}", "RW_FRONTEND_URL":"${RW_FRONTEND_URL}", "RW_SESSION_ID":"${RW_SESSION_ID}", "RW_USERNAME": "${RW_USERNAME}", "RW_WORKSPACE":"${RW_WORKSPACE}"}

    # Verify cluster connectivity
    ${connectivity}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} cluster-info --context ${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=30
    IF    ${connectivity.returncode} != 0
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Kubernetes cluster should be reachable via configured kubeconfig and context `${CONTEXT}`
        ...    actual=Unable to connect to Kubernetes cluster with context `${CONTEXT}`
        ...    title=Kubernetes Cluster Connectivity Check Failed for Context `${CONTEXT}`
        ...    reproduce_hint=${KUBERNETES_DISTRIBUTION_BINARY} cluster-info --context ${CONTEXT}
        ...    details=Failed to connect to the Kubernetes cluster. This may indicate an expired kubeconfig, network connectivity issues, or the cluster being unreachable.\n\nSTDOUT:\n${connectivity.stdout}\n\nSTDERR:\n${connectivity.stderr}
        ...    next_steps=Verify kubeconfig is valid and not expired\nCheck network connectivity to the cluster API server\nVerify the context '${CONTEXT}' is correctly configured\nCheck if the cluster is running and accessible
        BuiltIn.Fatal Error    Kubernetes cluster connectivity check failed for context '${CONTEXT}'. Aborting suite.
    END
