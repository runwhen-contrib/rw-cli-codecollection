*** Settings ***
Documentation       Counts the number of unhealthy cert-manager managed certificates in a namespace.
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes cert-manager Healthcheck
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Count Unready and Expired Certificates in Namespace `${NAMESPACE}`
    [Documentation]    Adds together the count of unready and expired certificates. A healthy SLI value is 0.
    [Tags]    certificate    status    count    health    certmanager    cert

    # Count expired certs
    ${expired_certs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get --context=${CONTEXT} -n ${NAMESPACE} certificates.cert-manager.io -ojson | jq '[.items[] | select(.status.notAfter != null) | {notAfter: .status.notAfter} | .notAfter |= (gsub("[-:TZ]"; "") | strptime("%Y%m%d%H%M%S") | mktime) | select(.notAfter < now)] | length'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${expired_count}=    Convert To Number    ${expired_certs.stdout}
    # Count unready certificates
    ${unready_certs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get --context=${CONTEXT} -n ${NAMESPACE} certificates.cert-manager.io -ojson | jq '[.items[] | select(.status.conditions[] | select(.type == "Ready" and .status == "False"))] | length'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${unready_count}=    Convert To Number    ${unready_certs.stdout}

    ${metric}=    Evaluate    ${expired_count} + ${unready_count}
    RW.Core.Push Metric    ${metric}    sub_name=cert_manager_health
    RW.Core.Push Metric    ${metric}


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${NAMESPACE}=    RW.Core.Import User Variable
    ...    NAMESPACE
    ...    type=string
    ...    description=The name of the Kubernetes namespace to scope actions and searching to. Supports csv list of namespaces.
    ...    pattern=\w*
    ...    default=cert-manager
    ...    example=cert-manager
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster

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
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}

