*** Settings ***
Documentation      Checks istio proxy sidecar injection status, high memory and cpu usage, warnings and errors in logs, valid certificates, configuration and verify istio installation.
Metadata           Author    Nbarola
Metadata           Display Name    Kubernetes Istio System Health
Metadata           Supports    Kubernetes   AKS EKS GKE OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.K8sHelper
Library             OperatingSystem
Library             String

Suite Setup         Suite Initialization

*** Tasks ***

Check Deployments for Istio Sidecar Injection for Cluster ${CLUSTER}
    [Documentation]    Checks all deployments in specified namespaces for Istio sidecar injection status
    [Tags]    
    ...    istio
    ...    sidecar
    ...    injection
    ...    deployment
    ${results}=    RW.CLI.Run Bash File
    ...    bash_file=check_istio_injection.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=false
    
 
    ${issues_list}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/issues.json
    ...    env=${env}
    ...    include_in_history=false


    # Process issues if any were found
    ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
    IF    len(@{issues}) > 0
        FOR    ${issue}    IN    @{issues}
            ${reproduce_cmd}=    Set Variable    kubectl get pods -n ${issue['namespace']} -l app=${issue['deployment']} -o jsonpath='{.items[*].spec.containers[*].name}'
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${reproduce_cmd}
            ...    next_steps=${issue['next_steps']}
        END
    END


    # Generate and add the formatted report
    ${formatted_report}=    RW.CLI.Run Bash File
    ...    bash_file=istio_sidecar_injection_report.sh
    ...    env=${env}
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${formatted_report.stdout}

Check Istio Sidecar resources usage for Cluster ${CLUSTER}
    [Documentation]    Checks all pods in specified namespaces for Istio sidecar resources usage
    [Tags]    
    ...    istio
    ...    sidecar
    ...    resources 
    ...    usage
    ${results}=    RW.CLI.Run Bash File
    ...    bash_file=istio_sidecar_resource_usage.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=false
    ${issues_list}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/istio_sidecar_resource_usage_issue.json
    ...    env=${env}
    ...    include_in_history=false

    ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
    IF    len(@{issues}) > 0
        FOR    ${issue}    IN    @{issues}
            ${reproduce_cmd}=    Set Variable    ${issue['reproduce_hint']}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${reproduce_cmd}
            ...    next_steps=${issue['next_steps']}
        END
    END
    ${usage_report}=    RW.CLI.Run Cli
    ...     cmd=cat ${OUTPUT_DIR}/istio_sidecar_resource_usage_report.txt
    ...     env=${env}
    ...     include_in_history=false

    RW.Core.Add Pre To Report   ${usage_report.stdout}


Verify Istio Istallation in Cluster ${CLUSTER}
    [Documentation]    Verify Istio Istallation in cluster ${CLUSTER}
    [Tags]    
    ...    istio
    ...    installation
    ${results}=    RW.CLI.Run Bash File
    ...    bash_file=istio_installation_verify.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=false
    ${issues_list}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/istio_installation_issues.json
    ...    env=${env}
    ...    include_in_history=false

    ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
    IF    len(@{issues}) > 0
        FOR    ${issue}    IN    @{issues}
            ${reproduce_cmd}=    Set Variable    ${issue['reproduce_hint']}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${reproduce_cmd}
            ...    next_steps=${issue['next_steps']}
        END
    END
    ${installation_report}=    RW.CLI.Run Cli
    ...     cmd=cat ${OUTPUT_DIR}/istio_installation_report.txt
    ...     env=${env}
    ...     include_in_history=false

    RW.Core.Add Pre To Report   ${installation_report.stdout}


Check Istio Controlplane logs in Cluster ${CLUSTER}
    [Documentation]    Check istio controlplane logs for known erros and warnings in cluster ${CLUSTER}
    [Tags]
    ...    istio
    ...    controlplane logs
    ${results}=    RW.CLI.Run Bash File
    ...    bash_file=istio_controlplane_logs.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=false
    ${issues_list}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/istio_controlplane_issues.json
    ...    env=${env}
    ...    include_in_history=false

    ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
    IF    len(@{issues}) > 0
        FOR    ${issue}    IN    @{issues}
            ${reproduce_cmd}=    Set Variable    ${issue['reproduce_hint']}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${reproduce_cmd}
            ...    next_steps=${issue['next_steps']}
        END
    END

    ${logs_report}=    RW.CLI.Run Cli
    ...     cmd=cat ${OUTPUT_DIR}/istio_controlplane_report.json
    ...     env=${env}
    ...     include_in_history=false
    RW.Core.Add Pre To Report   ${logs_report.stdout}

Check Istio Proxy logs in Cluster ${CLUSTER}
    [Documentation]    Check istio proxy logs for known erros and warnings in cluster ${CLUSTER}
    [Tags]
    ...    istio
    ...    proxy logs
    ${results}=    RW.CLI.Run Bash File
    ...    bash_file=istio_proxy_logs.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=false
    ${issues_list}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/istio_proxy_issues.json
    ...    env=${env}
    ...    include_in_history=false

    ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
    IF    len(@{issues}) > 0
        FOR    ${issue}    IN    @{issues}
            ${reproduce_cmd}=    Set Variable    ${issue['reproduce_hint']}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${reproduce_cmd}
            ...    next_steps=${issue['next_steps']}
        END
    END

    ${logs_report}=    RW.CLI.Run Cli
    ...     cmd=cat ${OUTPUT_DIR}/istio_proxy_report.json
    ...     env=${env}
    ...     include_in_history=false
    RW.Core.Add Pre To Report   ${logs_report.stdout}

Check Istio Components Certificates in Cluster ${CLUSTER}
    [Documentation]    Check Istio valid Root CA and mTLS Certificates in cluster ${CLUSTER}
    [Tags]
    ...    istio
    ...    mtls
    ${results}=    RW.CLI.Run Bash File
    ...    bash_file=istio_mtls_check.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=false
    ${issues_list}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/istio_mtls_issues.json
    ...    env=${env}
    ...    include_in_history=false

    ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
    IF    len(@{issues}) > 0
        FOR    ${issue}    IN    @{issues}
            ${reproduce_cmd}=    Set Variable    ${issue['reproduce_hint']}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${reproduce_cmd}
            ...    next_steps=${issue['next_steps']}
        END
    END
    ${mtls_report}=    RW.CLI.Run Cli
    ...     cmd=cat ${OUTPUT_DIR}/istio_mtls_report.txt
    ...     env=${env}
    ...     include_in_history=false
    RW.Core.Add Pre To Report   ${mtls_report.stdout}

Analyze Istio configurations in Cluster ${CLUSTER}
    [Documentation]    Check Istio configurations in cluster ${CLUSTER}
    [Tags]
    ...    istio
    ...    config
    ${results}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_istio_configurations.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=false
    ${issues_list}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/issues_istio_analyze.json
    ...    env=${env}
    ...    include_in_history=false

    ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
    IF    len(@{issues}) > 0
        FOR    ${issue}    IN    @{issues}
            ${reproduce_cmd}=    Set Variable    ${issue['reproduce_hint']}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${reproduce_cmd}
            ...    next_steps=${issue['next_steps']}
        END
    END
    ${analyze_report}=    RW.CLI.Run Cli
    ...     cmd=cat ${OUTPUT_DIR}/report_istio_analyze.txt
    ...     env=${env}
    ...     include_in_history=false
    RW.Core.Add Pre To Report   ${analyze_report.stdout}


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
    ${CLUSTER}=    RW.Core.Import User Variable    CLUSTER
    ...    type=string
    ...    description=Which Kubernetes cluster to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster

    ${EXCLUDED_NAMESPACES}=    RW.Core.Import User Variable    EXCLUDED_NAMESPACES
    ...    type=string
    ...    description=Comma-separated list of namespaces to exclude from checks (e.g., kube-system,istio-system).
    ...    pattern=\w*
    ...    example=kube-system,istio-system
    ...    default=kube-system

    ${CPU_USAGE_THRESHOLD}=    RW.Core.Import User Variable    CPU_USAGE_THRESHOLD
    ...    type=string
    ...    description=The Threshold for the CPU usage.
    ...    pattern=\w*
    ...    example=80
    ...    default=80

    ${MEMORY_USAGE_THRESHOLD}=    RW.Core.Import User Variable    MEMORY_USAGE_THRESHOLD
    ...    type=string
    ...    description=The Threshold for the MEMORY usage.
    ...    pattern=\w*
    ...    example=80
    ...    default=80
    
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${CLUSTER}    ${CLUSTER}
    Set Suite Variable    ${EXCLUDED_NAMESPACES}    ${EXCLUDED_NAMESPACES}
    Set Suite Variable    ${CPU_USAGE_THRESHOLD}    ${CPU_USAGE_THRESHOLD}
    Set Suite Variable    ${MEMORY_USAGE_THRESHOLD}    ${MEMORY_USAGE_THRESHOLD}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "CLUSTER":"${CLUSTER}", "EXCLUDED_NAMESPACES":"${EXCLUDED_NAMESPACES}", "CPU_USAGE_THRESHOLD":"${CPU_USAGE_THRESHOLD}", "MEMORY_USAGE_THRESHOLD":"${MEMORY_USAGE_THRESHOLD}", "OUTPUT_DIR":"${OUTPUT_DIR}", "CURDIR":"${CURDIR}"}

