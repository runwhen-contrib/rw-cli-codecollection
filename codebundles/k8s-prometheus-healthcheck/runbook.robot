*** Settings ***
Documentation       This taskset investigates the logs, state and health of Kubernetes Prometheus operator.
Metadata            Author    jon-funk
Metadata            Display Name    Kubeprometheus Operator Troubleshoot
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift,Prometheus

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
Check Prometheus Service Monitors in namespace `${NAMESPACE}`
    [Documentation]    Checks the selector mappings of service monitors are valid in the namespace
    [Tags]       access:read-only  prometheus
    ${sm_report}=    RW.CLI.Run Bash File
    ...    bash_file=validate_servicemonitors.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=false
    ${nextsteps}=    RW.CLI.Run Cli
    ...    cmd=echo "${sm_report.stdout}" | tail -n +2 | grep -i "next steps" -A 5
    ...    env=${env}
    ...    include_in_history=false
    # Check if ServiceMonitor mapping issues are found
    ${contains_investigate}=    Run Keyword And Return Status    Should Contain    ${sm_report.stdout}    Investigate the endpoints
    IF    ${contains_investigate}
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=All service monitors in the namespace are correctly mapped to their endpoints
        ...    actual=ServiceMonitors with incorrect mappings were found
        ...    title=Incorrect ServiceMonitor Mappings Found In Namespace `${NAMESPACE}`
        ...    details=${sm_report.stdout}
        ...    reproduce_hint=Check ServiceMonitor configurations and endpoint mappings
        ...    next_steps=${nextsteps.stdout}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Check For Successful Rule Setup in Kubernetes Namespace `${NAMESPACE}`
    [Documentation]    Inspects operator instance logs for failed rules setup
    [Tags]       access:read-only   prometheys
    Log To Console    Prometheus
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${PROM_NAMESPACE} logs $(${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${PROM_NAMESPACE} get pods -l app.kubernetes.io/name=prometheus -o=jsonpath='{.items[0].metadata.name}') -c prometheus | grep -iP "(load.*.fail)" || true
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    # Check if Prometheus scraping errors are found
    ${contains_error_1}=    Run Keyword And Return Status    Should Contain    ${rsp.stdout}    error
    IF    ${contains_error_1}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=No endpoint scraping errors found
        ...    actual=The Prometheus operator has scraping errors
        ...    title=Endpoint Scraping Errors Found for Prometheus Operator in Namespace `${NAMESPACE}`
        ...    details=Error logs found: ${rsp.stdout}
        ...    reproduce_hint=Check Prometheus operator logs and target endpoints
        ...    next_steps=Investigate the scraping endpoint and consider restarting it.
    END
    ${err_logs}=    Set Variable    ${rsp.stdout}
    IF    """${err_logs}""" == ""
        ${err_logs}=    Set Variable    No error logs found.
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Logs Found:\n ${rsp.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Verify Prometheus RBAC Can Access ServiceMonitors in Namespace `${PROM_NAMESPACE}`
    [Documentation]    Fetch operator rbac and verify it has ServiceMonitors in rbac.
    [Tags]       access:read-only   prometheus
    ${clusterrole}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get clusterrole/kube-prometheus-stack-operator -ojson
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${sm_check}=    RW.CLI.Run Cli
    ...    cmd=echo "${clusterrole.stdout}" | jq -r '.rules' | grep -i servicemonitors
    # Check if RBAC does not contain servicemonitors
    ${not_contains_servicemonitors}=    Run Keyword And Return Status    Should Not Contain    ${sm_check.stdout}    servicemonitors
    IF    ${not_contains_servicemonitors}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Prometheus Operator RBAC contains ServiceMonitors
        ...    actual=The Prometheus Operator RBAC does not contain ServiceMonitors
        ...    title=Missing Prometheus Operator RBAC in Namespace `${PROM_NAMESPACE}`
        ...    details=ServiceMonitors RBAC missing in: ${clusterrole.stdout}
        ...    reproduce_hint=Check Prometheus Operator ClusterRole configuration
        ...    next_steps=Inspect the deployment method for your Prometheus Operator and check for version-control drift, or if the role was manually changed.
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Inspect Prometheus Operator Logs for Scraping Errors in Namespace `${NAMESPACE}`
    [Documentation]    Inspect the prometheus operator logs for scraping errors and raise issues if any found
    [Tags]       access:read-only   prometheus    
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${PROM_NAMESPACE} logs $(${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${PROM_NAMESPACE} get pods -l app.kubernetes.io/name=prometheus -o=jsonpath='{.items[0].metadata.name}') -c prometheus | grep -iP "(scrape.*.error)" || true
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    # Check if Prometheus operator scraping errors are found
    ${contains_error_2}=    Run Keyword And Return Status    Should Contain    ${rsp.stdout}    error
    IF    ${contains_error_2}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=No endpoint scraping errors found
        ...    actual=The Prometheus operator has scraping errors
        ...    title=Endpoint Scraping Errors Found for Prometheus Operator in Namespace `${NAMESPACE}`
        ...    details=Error logs found: ${rsp.stdout}
        ...    reproduce_hint=Check Prometheus operator logs for scraping issues
        ...    next_steps=Investigate the scraping endpoint and consider restarting it.
    END
    ${err_logs}=    Set Variable    ${rsp.stdout}
    IF    """${err_logs}""" == ""
        ${err_logs}=    Set Variable    No error logs found.
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Logs Found:\n ${rsp.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Check Prometheus API Healthy in Namespace `${PROM_NAMESPACE}`
    [Documentation]    Ping Prometheus healthy API endpoint for a 200 response code.
    [Tags]       access:read-only   prometheus
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${PROM_NAMESPACE} exec $(${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${PROM_NAMESPACE} get pods -l app.kubernetes.io/name=prometheus -o=jsonpath='{.items[0].metadata.name}') --container prometheus -- wget -qO- -S 127.0.0.1:9090/-/healthy 2>&1 | grep "HTTP/" | awk '{print $2}'
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    # Check if Prometheus health API does not return 200
    ${not_contains_200}=    Run Keyword And Return Status    Should Not Contain    ${rsp.stdout}    200
    IF    ${not_contains_200}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=The Prometheus healthy endpoint returned a 200, indicating that it's healthy
        ...    actual=The healthy endpoint returned a non-200 response
        ...    title=Prometheus Health API Response Unhealthy in Namespace `${NAMESPACE}`
        ...    details=Received response ${rsp.stdout} from the Prometheus Operator health API in namespace `${NAMESPACE}`
        ...    reproduce_hint=Check Prometheus health endpoint and pod status
        ...    next_steps=Check Prometheus pod logs and restart if necessary
    END
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
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${PROM_NAMESPACE}    ${PROM_NAMESPACE}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}", "NAMESPACE":"${NAMESPACE}"}

    # Verify cluster connectivity
    RW.K8sHelper.Verify Cluster Connectivity
    ...    binary=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    context=${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
