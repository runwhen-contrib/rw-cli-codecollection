*** Settings ***
Documentation       Checks for Istio sidecar injection across deployments in all namespaces.
Metadata           Author    Helpful Assistant
Metadata           Display Name    Istio Sidecar Injection Check
Metadata           Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.K8sHelper
Library             OperatingSystem
Library             String

Suite Setup         Suite Initialization

*** Tasks ***

Check Deployments For Istio Sidecar Injection
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
    ...    include_in_history=true
    
    # Save command history for report
    ${history}=    RW.CLI.Pop Shell History
    ${commands_used}=    Set Variable    ${history.strip()}
    Create File    command_history.txt    Commands Used:\n${commands_used}

    # Extract issues and report from stdout
    ${stdout_lines}=    Split To Lines    ${results.stdout}
    # Find marker indices
    ${issues_start}=    Set Variable    -1
    ${issues_end}=    Set Variable    -1
    ${report_start}=    Set Variable    -1
    ${report_end}=    Set Variable    -1
    FOR    ${index}    ${line}    IN ENUMERATE    @{stdout_lines}
        IF    $line == "===ISSUES_START==="
            ${issues_start}=    Set Variable    ${index}
        ELSE IF    $line == "===ISSUES_END==="
            ${issues_end}=    Set Variable    ${index}
        ELSE IF    $line == "===REPORT_START==="
            ${report_start}=    Set Variable    ${index}
        ELSE IF    $line == "===REPORT_END==="
            ${report_end}=    Set Variable    ${index}
        END
    END

    # Get issues JSON
    ${issues_json}=    Set Variable    ${stdout_lines[${issues_start}+1:${issues_end}]}
    ${issues_json}=    Evaluate    "\\n".join(${issues_json})
    Create File    issues.json    ${issues_json}

    # Get report text
    ${report_text}=    Set Variable    ${stdout_lines[${report_start}+1:${report_end}]}
    ${report_text}=    Evaluate    "\\n".join(${report_text})
    Create File    report.txt    ${report_text}

    # Process issues if any were found
    ${rc}=    Run Keyword And Return Status    File Should Exist    issues.json
    IF    ${rc} == ${TRUE}
        ${issues}=    Evaluate    json.loads(r'''${issues_json}''')    json
        
        FOR    ${issue}    IN    @{issues}
            ${reproduce_cmd}=    Set Variable    kubectl get pods -n ${issue['namespace']} -l app=${issue['deployment']} -o jsonpath='{.items[*].spec.containers[*].name}'
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Deployment should have Istio sidecar injection configured properly
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${reproduce_cmd}
            ...    next_steps=${issue['next_steps']}
        END
    END

    # Save script output for report
    #Create File    report.txt    ${results.stdout}

    # Generate and add the formatted report
    ${formatted_report}=    RW.CLI.Run Bash File
    ...    bash_file=istio_report.sh
    ...    env=${env}
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${formatted_report.stdout}

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

    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${EXCLUDED_NAMESPACES}    ${EXCLUDED_NAMESPACES}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "EXCLUDED_NAMESPACES":"${EXCLUDED_NAMESPACES}"}

