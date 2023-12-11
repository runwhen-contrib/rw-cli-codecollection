*** Settings ***
Documentation       Provides a list of tasks that can remediate configuraiton issues with deployment manifests in gitops repositories. 
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes Deployment Triage
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.NextSteps
Library             OperatingSystem
Library             String

Suite Setup         Suite Initialization


*** Tasks ***

Check Readiness and Liveness Probe Configuration for Deployments in Namespace `${NAMESPACE}`
    [Documentation]    Fixes misconfigured readiness or liveness probe configurations for deployments in a namespace
    [Tags]
    ...    readiness
    ...    liveness
    ...    probe
    ...    workloads
    ...    errors
    ...    failure
    ...    restart
    ...    get
    ...    deployment
    ...    ${NAMESPACE}
    ${readiness_probe_health}=    RW.CLI.Run Bash File
    ...    bash_file=validate_probes.sh
    ...    cmd_override=./validate_probes.sh readinessProbe
    ...    env=${env}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
   ${recommendations}=    RW.CLI.Run Cli
    ...    cmd=echo '${readiness_probe_health.stdout}' | awk '/Recommended Next Steps:/ {flag=1; next} flag'
    ...    env=${env}
    ...    include_in_history=false
    IF     len($recommendations.stdout) > 0 
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Readiness probes should be configured and functional for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Issues found with readiness probe configuration for Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    title=Readiness Probe Configuration Issues with Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=${readiness_probe_health.stdout}
        ...    next_steps=${recommendations.stdout}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Readiness probe testing results:\n\n${readiness_probe_health.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${github_pat}=    RW.Core.Import Secret
    ...    github_pat
    ...    type=string
    ...    description=The GitHub Personal Access token used to create commits and open PRs against the GitOps repo.
    ...    pattern=\w*
    ${kubectl}=    RW.Core.Import Service    kubectl
    ...    description=The location service used to interpret shell commands.
    ...    default=kubectl-service.shared
    ...    example=kubectl-service.shared
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
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    ${HOME}=    RW.Core.Import User Variable    HOME
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${HOME}    ${HOME}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}", "HOME":"${HOME}", "GITHUB_PAT":"${GITHUB_PAT}"}
