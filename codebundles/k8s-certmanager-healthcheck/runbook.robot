*** Settings ***
Documentation       This taskset checks that your cert manager certificates are renewing as expected, raising issues when they are past due in the configured namespace
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes CertManager Healthcheck
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift,CertManager

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             DateTime
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Get Namespace Certificate Summary
    [Documentation]    Gets a list of certmanager certificates and summarize their information for review.
    [Tags]    tls    certificates    kubernetes    objects    expiration    summary    certmanager
    ${cert_info}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get certificates --context=${CONTEXT} -n ${NAMESPACE} -ojson | jq -r '.items[] | select(now < (.status.renewalTime|fromdate)) | "Namespace:" + .metadata.namespace + " URL:" + .spec.dnsNames[0] + " Renews:" + .status.renewalTime + " Expires:" + .status.notAfter'
    ...    render_in_commandlist=true
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${cert_info}
    ...    set_severity_level=3
    ...    set_issue_expected=No certificates found past their set renewal date in the namespace ${NAMESPACE}
    ...    set_issue_actual=Certificates were found in the namespace ${NAMESPACE} that are past their renewal time and not renewed
    ...    set_issue_title=Found certificates due for renewal in namespace ${NAMESPACE} that are not renewing
    ...    set_issue_details=CertManager certificates not renewing: "$_stdout" - investigate CertManager.
    ...    _line__raise_issue_if_contains=Namespace
    RW.Core.Add Pre To Report    Certificate Information:\n${cert_info.stdout}
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
