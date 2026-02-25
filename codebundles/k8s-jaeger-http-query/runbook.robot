*** Settings ***
Documentation       This taskset queries Jaeger API directly for trace details and parses the results
Metadata            Author    stewartshea
Metadata            Display Name    K8s Jaeger Query
Metadata            Supports    GKE EKS AKS Kubernetes    HTTP

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.K8sHelper

Suite Setup         Suite Initialization


*** Tasks ***
Query Traces in Jaeger for Unhealthy HTTP Response Codes in Namespace `${NAMESPACE}`
    [Documentation]    Query Jaeger for all services and report on any HTTP related trace errors
    [Tags]    jaeger    http    ingress    latency    errors    traces    kubernetes    data:logs-regexp
    ${http_traces}=    RW.CLI.Run Bash File
    ...    bash_file=query_jaeger_http_errors.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ${recommendations}=    RW.CLI.Run Cli
    ...    cmd=echo '${http_traces.stdout}' | awk '/Recommended Next Steps:/ {flag=1; next} flag'
    ...    env=${env}
    ...    include_in_history=false
    IF    $recommendations.stdout != ""
        ${recommendation_list}=    Evaluate    json.loads(r'''${recommendations.stdout}''')    json
        IF    len(@{recommendation_list}) > 0
            FOR    ${item}    IN    @{recommendation_list}
                RW.Core.Add Issue
                ...    severity=${item["severity"]}
                ...    expected=Service `${item["service"]}` should not have HTTP errors in namespace `${NAMESPACE}`
                ...    actual=Service `${item["service"]}` has HTTP errors in namespace `${NAMESPACE}`
                ...    title=${item["title"]}
                ...    reproduce_hint=${http_traces.cmd}
                ...    details=${item["details"]}
                ...    next_steps=${item["next_steps"]}
                ...    observed_at=${item["observed_at"]}
            END
        END
    END
    RW.Core.Add Pre To Report    ${http_traces.stdout}\n


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=The name of the Kubernetes namespace to scope actions and searching to.
    ...    pattern=\w*
    ...    example=my-namespace
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster
    ${SERVICE_EXCLUSIONS}=    RW.Core.Import User Variable    SERVICE_EXCLUSIONS
    ...    type=string
    ...    description=Comma separated list of serivces to exclude from the query
    ...    pattern=\w*
    ...    example=jaeger-all-in-one
    ...    default=none
   ${LOOKBACK}=    RW.Core.Import User Variable    LOOKBACK
    ...    type=string
    ...    description=The age to query for traces. Defaults to 5m. 
    ...    pattern=\w*
    ...    example=1h
    ...    default=5m
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${SERVICE_EXCLUSIONS}    ${SERVICE_EXCLUSIONS}
    Set Suite Variable    ${LOOKBACK}    ${LOOKBACK}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}", "SERVICE_EXCLUSIONS":"${SERVICE_EXCLUSIONS}"}

    # Verify cluster connectivity
    RW.K8sHelper.Verify Cluster Connectivity
    ...    binary=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    context=${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}

