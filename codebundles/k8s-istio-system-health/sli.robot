*** Settings ***
Documentation      Checks istio proxy sidecar injection status, high memory and cpu usage, warnings and errors in logs, valid certificates, configuration and verify istio installation.
Metadata           Author    Nbarola
Metadata           Display Name    Kubernetes Istio System Health
Metadata           Supports    Kubernetes Istio AKS EKS GKE OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.K8sHelper
Library             OperatingSystem
Library             String

Suite Setup         Suite Initialization

*** Tasks ***

Verify Istio Sidecar Injection for Cluster `${CONTEXT}`
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
    ...    cmd=cat issues.json
    ...    env=${env}
    ...    include_in_history=false

    ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
    ${sidecar_injection_score}=    Evaluate    1 if len(@{issues}) == 0 else 0
    Set Global Variable    ${sidecar_injection_score}

Check Istio Sidecar Resource Usage for Cluster `${CONTEXT}`
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
    ...    cmd=cat istio_sidecar_resource_usage_issue.json
    ...    env=${env}
    ...    include_in_history=false

    ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
    ${sidecar_resources_usage_score}=    Evaluate    1 if len(@{issues}) == 0 else 0
    Set Global Variable    ${sidecar_resources_usage_score}


Validate Istio Installation in Cluster `${CONTEXT}`
    [Documentation]    Verify Istio Istallation
    [Tags]    
    ...    istio
    ...    installation
    ${results}=    RW.CLI.Run Bash File
    ...    bash_file=istio_installation_verify.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=false
    ${issues_list}=    RW.CLI.Run Cli
    ...    cmd=cat istio_installation_issues.json
    ...    env=${env}
    ...    include_in_history=false

    ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
    ${installation_verify_score}=    Evaluate    1 if len(@{issues}) == 0 else 0
    Set Global Variable    ${installation_verify_score}


Check Istio Controlplane Logs For Errors in Cluster `${CONTEXT}`
    [Documentation]    Check controlplane logs for known errors and warnings in Cluster
    [Tags]
    ...    istio
    ...    logs
    ${results}=    RW.CLI.Run Bash File
    ...    bash_file=istio_controlplane_logs.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=false
    ${issues_list}=    RW.CLI.Run Cli
    ...    cmd=cat istio_controlplane_issues.json
    ...    env=${env}
    ...    include_in_history=false

    ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
    ${controlplane_logs_score}=    Evaluate    1 if len(@{issues}) == 0 else 0
    Set Global Variable    ${controlplane_logs_score}

Fetch Istio Proxy Logs in Cluster `${CONTEXT}`
    [Documentation]    Check istio proxy logs for known errors and warnings in cluster
    [Tags]
    ...    istio
    ...    proxy logs
    ${results}=    RW.CLI.Run Bash File
    ...    bash_file=istio_proxy_logs.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=false
    ${issues_list}=    RW.CLI.Run Cli
    ...    cmd=cat istio_proxy_issues.json
    ...    env=${env}
    ...    include_in_history=false

    ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
    ${proxy_logs_score}=    Evaluate    1 if len(@{issues}) == 0 else 0
    Set Global Variable    ${proxy_logs_score}

Verify Istio SSL Certificates in Cluster `${CONTEXT}`
    [Documentation]    Check Istio valid Root CA and mTLS Certificates in Cluster
    [Tags]
    ...    istio
    ...    mtls
    ${results}=    RW.CLI.Run Bash File
    ...    bash_file=istio_mtls_check.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=false
    ${issues_list}=    RW.CLI.Run Cli
    ...    cmd=cat istio_mtls_issues.json
    ...    env=${env}
    ...    include_in_history=false

    ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
    ${istio_certificate_score}=    Evaluate    1 if len(@{issues}) == 0 else 0
    Set Global Variable    ${istio_certificate_score}

Check Istio Configuration Health in Cluster `${CONTEXT}`
    [Documentation]    Check Istio configurations in Cluster
    [Tags]
    ...    istio
    ...    config
    ${results}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_istio_configurations.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=false
    ${issues_list}=    RW.CLI.Run Cli
    ...    cmd=cat issues_istio_analyze.json
    ...    env=${env}
    ...    include_in_history=false

    ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
    ${istio_configuration_score}=    Evaluate    1 if len(@{issues}) == 0 else 0
    Set Global Variable    ${istio_configuration_score}

Generate Health Score for Cluster ${CONTEXT}
    ${health_score}=    Evaluate  (${sidecar_injection_score} + ${sidecar_resources_usage_score} + ${installation_verify_score} + ${controlplane_logs_score} + ${proxy_logs_score} + ${istio_certificate_score} + ${istio_configuration_score}) / 7
    ${health_score}=    Convert to Number    ${health_score}  2
    RW.Core.Push Metric    ${health_score}

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
    Set Suite Variable    ${EXCLUDED_NAMESPACES}    ${EXCLUDED_NAMESPACES}
    Set Suite Variable    ${CPU_USAGE_THRESHOLD}    ${CPU_USAGE_THRESHOLD}
    Set Suite Variable    ${MEMORY_USAGE_THRESHOLD}    ${MEMORY_USAGE_THRESHOLD}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "EXCLUDED_NAMESPACES":"${EXCLUDED_NAMESPACES}", "CPU_USAGE_THRESHOLD":"${CPU_USAGE_THRESHOLD}", "MEMORY_USAGE_THRESHOLD":"${MEMORY_USAGE_THRESHOLD}"}

