*** Settings ***
Documentation       This taskset checks the health of Grafana Loki and its hash ring.
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes Grafana Loki Health Check

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.K8sHelper
Library             OperatingSystem
Library             DateTime
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Check Loki Ring API for Unhealthy Shards in Kubernetes Cluster `$${NAMESPACE}`
    [Documentation]    Request and inspect the state of the Loki hash rings for non-active (potentially unhealthy) shards.
    [Tags]      access:read-only  Loki      data:config
    # TODO: extend to dedicated script for parsing complex ring output/state
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} exec $(${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} get pods -l app.kubernetes.io/component=single-binary -o=jsonpath='{.items[0].metadata.name}') -- wget -q --header="Accept: application/json" -O - http://localhost:3100/ring | jq -r '.shards[] | select(.state != "ACTIVE") | {name: .id, state: .state}'
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    # Check if any non-active ring members were found (non-empty output means issues)
    ${has_non_active_members}=    Run Keyword And Return Status    Should Not Be Empty    ${rsp.stdout}
    IF    ${has_non_active_members}
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=The Loki hash ring shards should be active
        ...    actual=The Loki hash ring contains non-active members
        ...    title=Loki Hash Ring Contains Non-Active Members in Namespace `${NAMESPACE}`
        ...    details=The Loki ring API returned the following non-active members: ${rsp.stdout}
        ...    reproduce_hint=Check Loki ring API status and pod health
        ...    next_steps=Investigate the following ring members:\n${rsp.stdout}\nif their status does not return to ACTIVE shortly or they are not fully removed from the ring.
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Check Loki API Ready in Kubernetes Cluster `${NAMESPACE}`
    [Documentation]    Pings the internal Loki API to check it's ready.
    [Tags]      access:read-only  Loki      data:config
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} exec $(${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} get pods -l app.kubernetes.io/component=single-binary -o=jsonpath='{.items[0].metadata.name}') -- wget -q --header="Accept: application/json" -O - http://localhost:3100/ready
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${loki}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} get pods -l app.kubernetes.io/component=single-binary --no-headers -o=name
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    # Check if Loki API is not ready (should contain "ready" when healthy)
    ${api_not_ready}=    Run Keyword And Return Status    Should Not Contain    ${rsp.stdout}    ready
    IF    ${api_not_ready}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=The Loki API should be ready
        ...    actual=The Loki API is not ready
        ...    title=Loki API Not Ready in Namespace `${NAMESPACE}`
        ...    details=Received Response from Loki API: ${rsp.stdout}
        ...    reproduce_hint=Check Loki API endpoint and pod status
        ...    next_steps=Check the logs of the following loki pods for errors: ${loki.stdout}
    END
    RW.Core.Add Pre To Report    Loki API Response:\n${rsp.stdout}
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
    ...    example=loki
    ...    default=loki
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}", "NAMESPACE":"${NAMESPACE}"}

    # Verify cluster connectivity
    RW.K8sHelper.Verify Cluster Connectivity
    ...    binary=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    context=${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}

