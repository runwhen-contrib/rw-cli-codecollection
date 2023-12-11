*** Settings ***
Documentation       This taskset investigates the logs, state and health of Kubernetes Prometheus operator.
Metadata            Author    jon-funk
Metadata            Display Name    Kubeprometheus Operator Troubleshoot
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift,Prometheus

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
    ${sm_report}=    RW.CLI.Run Bash File
    ...    bash_file=validate_servicemonitors.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=false
    ${nextsteps}=    RW.CLI.Run Cli
    ...    cmd=echo "${sm_report.stdout}" | tail -n +2 | grep -i "next steps" -A 5
    ...    env=${env}
    ...    include_in_history=false
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${sm_report}
    ...    set_severity_level=3
    ...    set_issue_expected=All service monitors in the namespace are correctly mapped to their endpoints
    ...    set_issue_actual=ServiceMonitors with incorrect mappings were found
    ...    set_issue_title=Incorrect ServiceMonitor Mappings Found In ${NAMESPACE}
    ...    set_issue_details=${sm_report.stdout}
    ...    set_issue_next_steps=${nextsteps.stdout}
    ...    _line__raise_issue_if_contains=Investigate the endpoints
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Check For Successful Rule Setup
    [Documentation]    Inspects operator instance logs for failed rules setup
    Log To Console    Prometheus
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${PROM_NAMESPACE} logs $(${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${PROM_NAMESPACE} get pods -l app.kubernetes.io/name=prometheus -o=jsonpath='{.items[0].metadata.name}') -c prometheus | grep -iP "(load.*.fail)" || true
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${rsp}
    ...    set_severity_level=2
    ...    set_issue_expected=No endpoint scraping errors found
    ...    set_issue_actual=The Prometheus operator has scraping errors
    ...    set_issue_title=Endpoint Scraping Errors found for Prometheus Operator in ${NAMESPACE}
    ...    set_issue_details=Error logs found: ${rsp.stdout}
    ...    set_issue_next_steps=Investigate the scraping endpoint specified in $_line and consider restarting it.
    ...    _line__raise_issue_if_contains=error
    ${err_logs}=    Set Variable    ${rsp.stdout}
    IF    """${err_logs}""" == ""
        ${err_logs}=    Set Variable    No error logs found.
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Logs Found:\n ${rsp.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Verify Prometheus RBAC Can Access ServiceMonitors
    [Documentation]    Fetch operator rbac and verify it has ServiceMonitors in rbac.
    ${clusterrole}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get clusterrole/kube-prometheus-stack-operator -ojson
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${sm_check}=    RW.CLI.Run Cli
    ...    cmd=echo "${clusterrole.stdout}" | jq -r '.rules' | grep -i servicemonitors
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${sm_check}
    ...    set_severity_level=2
    ...    set_issue_expected=Prometheus Operator RBAC contains ServiceMonitors
    ...    set_issue_actual=The Prometheus Operator RBAC does not contain ServiceMonitors
    ...    set_issue_title=Missing Prometheus Operator RBAC in ${PROM_NAMESPACE}
    ...    set_issue_details=ServiceMonitors RBAC missing in: ${clusterrole.stdout}
    ...    set_issue_next_steps=Inspect the deployment method for your Prometheus Operator and check for version-control drift, or if the role was manually changed.
    ...    _line__raise_issue_if_ncontains=servicemonitors
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Identify Endpoint Scraping Errors
    [Documentation]    Inspect the prometheus operator logs for scraping errors and raise issues if any found
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${PROM_NAMESPACE} logs $(${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${PROM_NAMESPACE} get pods -l app.kubernetes.io/name=prometheus -o=jsonpath='{.items[0].metadata.name}') -c prometheus | grep -iP "(scrape.*.error)" || true
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${rsp}
    ...    set_severity_level=2
    ...    set_issue_expected=No endpoint scraping errors found
    ...    set_issue_actual=The Prometheus operator has scraping errors
    ...    set_issue_title=Endpoint Scraping Errors found for Prometheus Operator in ${NAMESPACE}
    ...    set_issue_details=Error logs found: ${rsp.stdout}
    ...    set_issue_next_steps=Investigate the scraping endpoint specified in $_line and consider restarting it.
    ...    _line__raise_issue_if_contains=error
    ${err_logs}=    Set Variable    ${rsp.stdout}
    IF    """${err_logs}""" == ""
        ${err_logs}=    Set Variable    No error logs found.
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Logs Found:\n ${rsp.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Check Prometheus API Healthy
    [Documentation]    Ping Prometheus healthy API endpoint for a 200 response code.
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${PROM_NAMESPACE} exec $(${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${PROM_NAMESPACE} get pods -l app.kubernetes.io/name=prometheus -o=jsonpath='{.items[0].metadata.name}') --container prometheus -- wget -qO- -S 127.0.0.1:9090/-/healthy 2>&1 | grep "HTTP/" | awk '{print $2}'
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${rsp}
    ...    set_severity_level=2
    ...    set_issue_expected=The Prometheus healthy endpoint returned a 200, indicating that it's healthy.
    ...    set_issue_actual=The healthy endpoint returned a non-200 response.
    ...    set_issue_title=Prometheus Health API Response Unhealthy
    ...    set_issue_details=Received response $_line from the Prometheus Operator health API in namespace ${NAMESPACE}
    ...    _line__raise_issue_if_ncontains=200
    RW.Core.Add Pre To Report    API Response:\n${rsp.stdout}
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
