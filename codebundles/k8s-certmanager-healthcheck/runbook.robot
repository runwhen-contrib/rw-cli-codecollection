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
Library             String

Suite Setup         Suite Initialization


*** Tasks ***
Get Namespace Certificate Summary for Namespace `${NAMESPACE}`
    [Documentation]    Gets a list of certmanager certificates that are due for renewal and summarize their information for review.
    [Tags]    tls    certificates    kubernetes    objects    expiration    summary    certmanager    ${NAMESPACE}
    ${cert_info}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get certificates.cert-manager.io --context=${CONTEXT} -n ${NAMESPACE} -ojson | jq -r --arg now "$(date +%Y-%m-%dT%H:%M:%SZ)" '.items[] | select(.status.conditions[] | select(.type == "Ready" and .status == "True")) | select(.status.renewalTime) | select((.status.notAfter | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) <= ($now | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)) | "Namespace:" + .metadata.namespace + " URL:" + .spec.dnsNames[0] + " Renews:" + .status.renewalTime + " Expires:" + .status.notAfter'
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${cert_info}
    ...    set_severity_level=3
    ...    set_issue_expected=No certificates found past their set renewal date in the namespace `${NAMESPACE}`
    ...    set_issue_actual=Certificates were found in the namespace `${NAMESPACE}` that are past their renewal time and not renewed
    ...    set_issue_title=Found certificates due for renewal in namespace `${NAMESPACE}` that are not renewing
    ...    set_issue_details=CertManager certificates not renewing: "$_stdout" - investigate CertManager.
    ...    set_issue_next_steps=Find Failed Certificate Requests and Identify Issues for Namespace `${NAMESPACE}`
    ...    _line__raise_issue_if_contains=Namespace
    RW.Core.Add Pre To Report    Certificate Information:\n${cert_info.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Find Failed Certificate Requests and Identify Issues for Namespace `${NAMESPACE}`
    [Documentation]    Gets a list of failed certmanager certificates and summarize their issues.
    [Tags]    tls    certificates    kubernetes    objects    failed    certificaterequest    certmanager    ${NAMESPACE}
    ${failed_certificaterequests}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get certificaterequests.cert-manager.io --context=${CONTEXT} -n ${NAMESPACE} -o json | jq -r '.items[] | select(.status.conditions[] | select(.type == "Ready" and .status != "True")) | {certRequest: .metadata.name, certificate: (.metadata.ownerReferences[].name), issuer: .spec.issuerRef.name, readyStatus: (.status.conditions[] | select(.type == "Ready")).status, readyMessage: (.status.conditions[] | select(.type == "Ready")).message, approvedStatus: (.status.conditions[] | select(.type == "Approved")).status, approvedMessage: (.status.conditions[] | select(.type == "Approved")).message} | "\\nCertificateRequest: \\(.certRequest)", "Certificate: \\(.certificate)", "Issuer: \\(.issuer)", "Ready Status: \\(.readyStatus)", "Ready Message: \\(.readyMessage)", "Approved Status: \\(.approvedStatus)", "Approved Message: \\(.approvedMessage)\\n------------"'
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${failed_cert_list}=    Split String    ${failed_certificaterequests.stdout}    ------------
    IF    len($failed_cert_list) > 0
        FOR    ${item}    IN    @{failed_cert_list}
            ${is_not_just_newline}=    Evaluate    '''${item}'''.strip() != ''
            IF    ${is_not_just_newline}
                ${ready_message}=    RW.CLI.Run Cli
                ...    cmd=echo '${item}' | grep "Ready Message:" | sed 's/^Ready Message: //' | sed 's/ *$//' | tr -d '\n'
                ...    env=${env}
                ...    include_in_history=false
                ${certificate_name}=    RW.CLI.Run Cli
                ...    cmd=echo '${item}' | grep "Certificate:" | sed 's/^Certificate: //' | sed 's/ *$//' | tr -d '\n'
                ...    env=${env}
                ...    include_in_history=false
                ${issuer_name}=    RW.CLI.Run Cli
                ...    cmd=echo '${item}' | grep "Issuer:" | sed 's/^Issuer: //' | sed 's/ *$//' | tr -d '\n'
                ...    env=${env}
                ...    include_in_history=false
                ${item_next_steps}=    RW.CLI.Run Bash File
                ...    bash_file=certificate_next_steps.sh
                ...    cmd_override=./certificate_next_steps.sh "${ready_message.stdout}" "${certificate_name.stdout}" "${Issuer_name.stdout}"
                ...    env=${env}
                ...    secret_file__kubeconfig=${kubeconfig}
                ...    include_in_history=False
                RW.Core.Add Issue
                ...    severity=2
                ...    expected=All certifiactes to be ready in ${NAMESPACE}
                ...    actual=Certificates are not ready in ${NAMESPACE}
                ...    title=Certificate `${certificate_name.stdout}` has failed in namespace `${NAMESPACE}`
                ...    details=CertManager certificates failure details: ${item}.
                ...    reproduce_hint=${failed_certificaterequests.cmd}
                ...    next_steps=${item_next_steps.stdout}
            END
        END
    END
    RW.Core.Add Pre To Report    Certificate Information:\n${failed_certificaterequests.stdout}
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
