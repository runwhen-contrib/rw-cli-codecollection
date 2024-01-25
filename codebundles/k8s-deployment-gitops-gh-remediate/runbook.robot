*** Settings ***
Documentation       Provides a list of tasks that can remediate configuraiton issues with deployment manifests in GitHub based gitops repositories.
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes GitOps GitHub Remediation
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift,FluxCD,ArgoCD

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.NextSteps
Library             OperatingSystem
Library             String

Suite Setup         Suite Initialization


*** Tasks ***
Remediate Readiness and Liveness Probe GitOps Manifests Namespace `${NAMESPACE}`
    [Documentation]    Fixes misconfigured readiness or liveness probe configurations for deployments in a namespace
    [Tags]    readiness    liveness    probe    deployment    remediate    gitops    ${NAMESPACE}
    ${probe_health}=    RW.CLI.Run Bash File
    ...    bash_file=validate_all_probes.sh
    ...    cmd_override=./validate_all_probes.sh deployment ${NAMESPACE}
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
    ${recommendations}=    RW.CLI.Run Cli
    ...    cmd=echo '${gh_updates.stdout}' | awk '/Recommended Next Steps:/ {flag=1; next} flag'
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
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Readiness probe testing results:\n\n${probe_health.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${probe_health.cmd}

Increase ResourceQuota for Namespace `${NAMESPACE}`
    [Documentation]    Looks for a resourcequota object in the namespace and updates it if possible
    [Tags]    resourcequota    quota    namespace    remediate    gitops    ${NAMESPACE}
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
    ${quota_recommendation_list}=    Evaluate    json.loads(r'''${quota_recommendations.stdout}''')    json
    IF    len(@{quota_recommendation_list}) > 0
        ${gh_updates}=    RW.CLI.Run Bash File
        ...    bash_file=update_github_manifests.sh
        ...    cmd_override=./update_github_manifests.sh '${quota_recommendations.stdout}'
        ...    env=${env}
        ...    include_in_history=False
        ...    secret_file__kubeconfig=${kubeconfig}
    END
    ${recommendations}=    RW.CLI.Run Cli
    ...    cmd=echo '${gh_updates.stdout}' | awk '/Recommended Next Steps:/ {flag=1; next} flag'
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
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add To Report    ${quota_usage.stdout}\n
    RW.Core.Add Pre To Report    Commands Used: ${quota_usage.cmd}


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
    ${HOME}=    RW.Core.Import User Variable    HOME
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
    Set Suite Variable    ${HOME}    ${HOME}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}", "HOME":"${HOME}", "GITHUB_TOKEN":"${github_token.value}", "RW_TASK_TITLES":"${RW_TASK_STRING}", "RW_FRONTEND_URL":"${RW_FRONTEND_URL}", "RW_SESSION_ID":"${RW_SESSION_ID}", "RW_USERNAME": "${RW_USERNAME}", "RW_WORKSPACE":"${RW_WORKSPACE}"}
