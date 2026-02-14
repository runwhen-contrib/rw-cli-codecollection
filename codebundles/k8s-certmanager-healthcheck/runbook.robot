*** Settings ***
Documentation       Checks the overall health of certificates in a namespace that are managed by cert-manager.
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes cert-manager Healthcheck
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift,cert-manager

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.K8sHelper
Library             OperatingSystem
Library             DateTime
Library             Collections
Library             String

Suite Setup         Suite Initialization


*** Tasks ***
Get Namespace Certificate Summary for Namespace `${NAMESPACE}`
    [Documentation]    Gets a list of cert-manager certificates that are due for renewal and summarize their information for review.
    [Tags]    tls    certificates    kubernetes    objects    expiration    summary    cert-manager
    ${cert_info}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get certificates.cert-manager.io --context=${CONTEXT} -n ${NAMESPACE} -ojson | jq -r --arg now "$(date +%Y-%m-%dT%H:%M:%SZ)" '.items[] | select(.status.conditions[] | select(.type == "Ready" and .status == "True")) | select(.status.renewalTime) | select((.status.notAfter | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) <= ($now | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)) | "Namespace:" + .metadata.namespace + " URL:" + .spec.dnsNames[0] + " Renews:" + .status.renewalTime + " Expires:" + .status.notAfter'
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    # Check if any certificates are due for renewal
    ${contains_namespace}=    Run Keyword And Return Status    Should Contain    ${cert_info.stdout}    Namespace
    IF    ${contains_namespace}
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=No certificates found past their set renewal date in the namespace `${NAMESPACE}`
        ...    actual=Certificates were found in the namespace `${NAMESPACE}` that are past their renewal time and not renewed
        ...    title=Found Certificates Due for Renewal in Namespace `${NAMESPACE}` That Are Not Renewing
        ...    details=cert-manager certificates not renewing: ${cert_info.stdout}
        ...    reproduce_hint=Check certificate status and cert-manager logs
        ...    next_steps=Find Failed Certificate Requests and Identify Issues for Namespace `${NAMESPACE}` \nCheck Logs for Cert-Manager Deployment in Cluster `${CONTEXT}`
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    **Certificate Summary for Namespace `${NAMESPACE}`**\n\n${cert_info.stdout}\n\n**Commands Used:** ${history}

Find Unhealthy Certificates in Namespace `${NAMESPACE}`
    [Documentation]    Gets a list of cert-manager certificates are not available.
    [Tags]    tls    certificates    kubernetes    cert-manager    failed
    ${unready_certs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get --context=${CONTEXT} -n ${NAMESPACE} certificates.cert-manager.io -ojson | jq '[.items[] | select(.status.conditions[] | select(.type == "Ready" and .status == "False")) | . + {observedAt: (.status.conditions[] | select(.type == "Ready" and .status == "False") | .lastTransitionTime)}]'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true

    ${unready_cert_list}=    Evaluate    json.loads(r'''${unready_certs.stdout}''')    json
    IF    len(@{unready_cert_list}) > 0
        FOR    ${item}    IN    @{unready_cert_list}
            ${observed_at}=    Evaluate    $item.get("observedAt", "")
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Certificates should be ready `${NAMESPACE}`
            ...    actual=Certificates in namespace `${NAMESPACE}` are not ready.
            ...    title= Certificate `${item["metadata"]["name"]}` is not available in namespace `${NAMESPACE}`.
            ...    reproduce_hint=${unready_certs.cmd}
            ...    details=${item}
            ...    next_steps=Find Failed Certificate Requests and Identify Issues for Namespace `${NAMESPACE}` \nCheck Logs for cert-manager Deployment in Cluster `${CONTEXT}`
            ...    observed_at=${observed_at}
        END
    END

    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    **Unready Certificates in Namespace `${NAMESPACE}`**\n\n${unready_certs.stdout}\n\n**Commands Used:** ${history}

Find Failed Certificate Requests and Identify Issues for Namespace `${NAMESPACE}`
    [Documentation]    Gets a list of failed cert-manager certificates and summarize their issues.
    [Tags]
    ...    tls
    ...    certificates
    ...    kubernetes
    ...    objects
    ...    failed
    ...    certificaterequest
    ...    cert-manager
    ...    ${namespace}
    ${failed_certificaterequests}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get certificaterequests.cert-manager.io --context=${CONTEXT} -n ${NAMESPACE} -o json | jq -r '.items[] | select(.status.conditions[] | select(.type == "Ready" and .status != "True")) | {certRequest: .metadata.name, certificate: (.metadata.ownerReferences[].name), issuer: .spec.issuerRef.name, readyStatus: (.status.conditions[] | select(.type == "Ready")).status, readyMessage: (.status.conditions[] | select(.type == "Ready")).message, approvedStatus: (.status.conditions[] | select(.type == "Approved")).status, approvedMessage: (.status.conditions[] | select(.type == "Approved")).message, observedAt: ((.status.conditions[] | select(.type == "Ready")).lastTransitionTime // "")} | "\\nCertificateRequest: \\(.certRequest)", "Certificate: \\(.certificate)", "Issuer: \\(.issuer)", "Ready Status: \\(.readyStatus)", "Ready Message: \\(.readyMessage)", "Approved Status: \\(.approvedStatus)", "Approved Message: \\(.approvedMessage)", "Observed At: \\(.observedAt)\\n------------"'
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
                ${observed_at}=    RW.CLI.Run Cli
                ...    cmd=echo '${item}' | grep "Observed At:" | sed 's/^Observed At: //' | sed 's/ *$//' | tr -d '\n'
                ...    env=${env}
                ...    include_in_history=false
                ${item_next_steps}=    RW.CLI.Run Bash File
                ...    bash_file=certificate_next_steps.sh
                ...    cmd_override=./certificate_next_steps.sh "${ready_message.stdout}" "${certificate_name.stdout}" "${issuer_name.stdout}"
                ...    env=${env}
                ...    secret_file__kubeconfig=${kubeconfig}
                ...    include_in_history=False
                RW.Core.Add Issue
                ...    severity=2
                ...    expected=All certifiactes to be ready in ${NAMESPACE}
                ...    actual=Certificates are not ready in ${NAMESPACE}
                ...    title=Certificate `${certificate_name.stdout}` has failed in namespace `${NAMESPACE}`
                ...    details=cert-manager certificates failure details: ${item}.
                ...    reproduce_hint=${failed_certificaterequests.cmd}
                ...    next_steps=${item_next_steps.stdout}
                ...    observed_at=${observed_at.stdout}
            END
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    **Failed Certificate Requests Analysis for Namespace `${NAMESPACE}`**\n\n${failed_certificaterequests.stdout}\n\n**Commands Used:** ${history}


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
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
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}

    # Verify cluster connectivity
    RW.K8sHelper.Verify Cluster Connectivity
    ...    binary=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    context=${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
