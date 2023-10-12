*** Settings ***
Documentation       This taskset investigates the logs and health of a Kubeprometheus operator.
Metadata            Author    jon-funk
Metadata            Display Name    Kubeprometheus Operator Healthcheck
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift,Redis

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             DateTime
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Check Prometheus Service Monitors
    [Documentation]    Checks the selector mappings of service monitors are valid in the namespace
    Log To Console    Prometheus

Check For Successful Rule Setup
    [Documentation]    Inspects operator instance logs for failed rules setup
    Log To Console    Prometheus
# python@1426b98fefc1:/app$ kubectl logs statefulset/prometheus-kube-prometheus-stack-prometheus -n kube-prometheus-stack | grep rule

Verify Prometheus RBAC Can Access ServiceMonitors
    [Documentation]    Fetch rbac yaml and look for list, get, watch in permissions
    Log To Console    ph

Identify Endpoint Scraping Errors
    [Documentation]    Inspect the prometheus operator logs for scraping errors and raise issues if any found
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${PROM_NAMESPACE} logs $(${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${PROM_NAMESPACE} get pods -l app.kubernetes.io/name=prometheus -o=jsonpath='{.items[0].metadata.name}') -c prometheus | grep -i "scrape.*error"
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${rsp}
    ...    set_severity_level=2
    ...    set_issue_expected=No endpoint scraping errors found
    ...    set_issue_actual=The Prometheus operator has scraping errors
    ...    set_issue_title=Endpoint Scraping Errors found for operator in ${NAMESPACE}
    ...    set_issue_details=Found $_line in namespace ${NAMESPACE}\nCheck if the redis workload is healthy and available. Attempt to run a 'redis-cli PING' directly on the workload and verify the response which should be PONG.
    ...    _line__raise_issue_if_ncontains=PONG
    RW.Core.Add Pre To Report    Redis Response:\n${rsp.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Check Prometheus API Healthy
    [Documentation]    Ping healthy API endpoint
    Log To Console    ph
# kubectl -n kube-prometheus-stack exec pod/prometheus-kube-prometheus-stack-prometheus-0 --container prometheus -- wget -qO- -S 127.0.0.1:9090/-/healthy 2>&1 | grep "HTTP/" | awk '{print $2}'
# POD_NAME=$(kubectl -n kube-prometheus-stack get pods -l app.kubernetes.io/name=prometheus -o=jsonpath='{.items[0].metadata.name}')
# kubectl -n kube-prometheus-stack exec $POD_NAME --container prometheus -- wget -qO- -S 127.0.0.1:9090/-/healthy 2>&1 | grep "HTTP/" | awk '{print $2}'


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
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}
