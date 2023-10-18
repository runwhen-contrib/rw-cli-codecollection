*** Settings ***
Documentation       This taskset checks the health of Grafana Loki and its hash ring.
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes Grafana Loki Health Check

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             DateTime
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Check Loki Ring API
    [Documentation]    Request and inspect the state of the Loki hash rings for non-active (potentially unhealthy) shards.
    # TODO: extend to dedicated script for parsing complex ring output/state
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} exec $(${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${PROM_NAMESPACE} get pods -l app.kubernetes.io/component=single-binary -o=jsonpath='{.items[0].metadata.name}') -- wget -q --header="Accept: application/json" -O - http://localhost:3100/ring | jq -r '.shards[] | select(.state != "ACTIVE") | {name: .id, state: .state}'
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${rsp}
    ...    set_severity_level=3
    ...    set_issue_expected=The Loki hash ring shards should be active.
    ...    set_issue_actual=The Loki hash ring contains non-active members.
    ...    set_issue_title=Loki Hash Ring Contains Non-Active Members
    ...    set_issue_details=The Loki ring API returned the following non-active members: ${rsp.stdout}
    ...    set_issue_next_steps=Investigate the following ring members: ${rsp.stdout} if their status does not return to ACTIVE shortly or they are fully removed from the ring.
    ...    _line__raise_issue_if_ncontains=ACTIVE
    RW.Core.Add Pre To Report    Ring API Response:\n${rsp.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Check Loki API Ready
    [Documentation]    Pings the internal Loki API to check it's ready.
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} exec $(${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${PROM_NAMESPACE} get pods -l app.kubernetes.io/component=single-binary -o=jsonpath='{.items[0].metadata.name}') -- wget -q --header="Accept: application/json" -O - http://localhost:3100/ready
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${loki}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} get pods -l app.kubernetes.io/component=single-binary --no-headers -o=name
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${rsp}
    ...    set_severity_level=2
    ...    set_issue_expected=The Loki API should be ready
    ...    set_issue_actual=The Loki API is not ready
    ...    set_issue_title=Loki API Not Ready
    ...    set_issue_details=Received Response from Loki API: ${rsp.stdout}
    ...    set_issue_next_steps=Check the logs of the following loki pods for errors: ${loki.stdout}
    ...    _line__raise_issue_if_ncontains=ready
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
    ...    example=loki
    ...    default=loki
    ${PROM_NAMESPACE}=    RW.Core.Import User Variable    PROM_NAMESPACE
    ...    type=string
    ...    description=The name of the namespace that kubeprometheus resides in.
    ...    pattern=\w*
    ...    example=kube-prometheus-stack
    ...    default=kube-prometheus-stack
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${PROM_NAMESPACE}    ${PROM_NAMESPACE}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}", "NAMESPACE":"${NAMESPACE}"}
