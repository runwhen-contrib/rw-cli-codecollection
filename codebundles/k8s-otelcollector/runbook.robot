*** Settings ***
Documentation       This taskset performs diagnostic checks on a OpenTelemetry Collector to ensure it's pushing metrics.
Metadata            Author    jon-funk
Metadata            Display Name    K8s OpenTelemetry Collector Health
Metadata            Supports    GKE EKS AKS Kubernetes    OpenTelemetry otel collector

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Query Collector Queued Spans in Namespace `${NAMESPACE}`
    [Documentation]    Query the collector metrics endpoint and inspect queue size
    [Tags]     access:read-only  otel-collector    metrics    queued    back pressure
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=otel_metrics_check.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    IF    ${process.returncode} > 0
        ${issue_timestamp}=    RW.Core.Get Issue Timestamp

        RW.Core.Add Issue    title=OpenTelemetry Span Queue Growing
        ...    severity=3
        ...    next_steps=Check OpenTelemetry backend is available in `${NAMESPACE}` and that the collector has enough resources, and that the collector's configmap is up-to-date.
        ...    expected=Queue size for spans should not be past threshold of 500
        ...    actual=Queue size of 500 or larger found
        ...    reproduce_hint=Run otel_metrics_check.sh
        ...    details=${process.stdout}
        ...    observed_at=${issue_timestamp}
    END
    RW.Core.Add Pre To Report    ${process.stdout}\n

Check OpenTelemetry Collector Logs For Errors In Namespace `${NAMESPACE}`
    [Documentation]    Fetch logs and check for errors
    [Tags]     access:read-only  otel-collector    metrics    errors    logs
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=otel_error_check.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    IF    ${process.returncode} > 0
        ${issue_timestamp}=    RW.Core.Get Issue Timestamp

        RW.Core.Add Issue    title=OpenTelemetry Collector Has Error Logs
        ...    severity=3
        ...    next_steps=Tail OpenTelemetry Collector Logs In Namespace `${NAMESPACE}` For Stacktraces
        ...    expected=Logs do not contain errors
        ...    actual=Found error logs
        ...    reproduce_hint=Run otel_error_check.sh
        ...    details=${process.stdout}
        ...    observed_at=${issue_timestamp}
    END
    RW.Core.Add Pre To Report    ${process.stdout}\n

Query OpenTelemetry Logs For Dropped Spans In Namespace `${NAMESPACE}`
    [Documentation]    Query the collector logs for dropped spans from errors
    [Tags]     access:read-only  otel-collector    metrics    errors    logs    dropped    rejected
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=otel_dropped_check.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    IF    ${process.returncode} > 0
        ${issue_timestamp}=    RW.Core.Get Issue Timestamp

        RW.Core.Add Issue    title=OpenTelemetry Collector Logs Have Dropped Spans
        ...    severity=3
        ...    next_steps=Tail OpenTelemetry Collector Logs In Namespace `${NAMESPACE}` For Stacktraces
        ...    expected=Logs do not contain dropped span entries
        ...    actual=Found dropped span entries
        ...    reproduce_hint=Run otel_dropped_check.sh
        ...    details=${process.stdout}
        ...    observed_at=${issue_timestamp}
    END
    RW.Core.Add Pre To Report    ${process.stdout}\n

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
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    ${WORKLOAD_SERVICE}=    RW.Core.Import User Variable    WORKLOAD_SERVICE
    ...    type=string
    ...    description=The service name used to curl the otel collector metrics endpoint.
    ...    example=otel-demo-otelcol
    ...    default=otel-demo-otelcol
    ${WORKLOAD_NAME}=    RW.Core.Import User Variable    WORKLOAD_NAME
    ...    type=string
    ...    description=The workload name to act as a bastion-host. The collector can be used, or a bastion host depending on networking requirements.
    ...    example=deployment/otel-demo-otelcol
    ...    default=deployment/otel-demo-otelcol
    ${METRICS_PORT}=    RW.Core.Import User Variable    METRICS_PORT
    ...    type=string
    ...    description=The port used by the collector to serve its metrics at. This will be scraped.
    ...    example=8888
    ...    default=8888
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${WORKLOAD_SERVICE}    ${WORKLOAD_SERVICE}
    Set Suite Variable    ${WORKLOAD_NAME}    ${WORKLOAD_NAME}
    Set Suite Variable    ${METRICS_PORT}    ${METRICS_PORT}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}", "METRICS_PORT":"${METRICS_PORT}", "WORKLOAD_NAME":"${WORKLOAD_NAME}", "WORKLOAD_SERVICE":"${WORKLOAD_SERVICE}"}
