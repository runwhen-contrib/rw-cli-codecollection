*** Settings ***
Documentation       Exposes LiteLLM proxy health via HTTP APIs (liveness, readiness, models, optional deep checks, integrations) plus optional kubectl Service correlation.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Kubernetes LiteLLM Proxy API Health
Metadata            Supports    Kubernetes    AKS    EKS    GKE    OpenShift    LiteLLM    HTTP

Force Tags          Kubernetes    LiteLLM    HTTP    proxy    health

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check LiteLLM Liveness Endpoint for Proxy `${LITELLM_SERVICE_NAME}`
    [Documentation]    Calls GET /health/liveliness (or /health/live) to confirm the proxy responds without invoking upstream LLM APIs.
    [Tags]    Kubernetes    LiteLLM    liveness    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-litellm-liveness.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-litellm-liveness.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat litellm_liveness_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for liveness task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=LiteLLM liveness endpoint should return HTTP 200 for a healthy proxy process
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Liveness results:\n${result.stdout}

Check LiteLLM Readiness and Dependencies for Proxy `${LITELLM_SERVICE_NAME}`
    [Documentation]    Calls GET /health/readiness to surface database and cache connectivity and proxy version.
    [Tags]    Kubernetes    LiteLLM    readiness    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-litellm-readiness.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-litellm-readiness.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat litellm_readiness_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for readiness task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Readiness should report connected database and healthy dependencies for traffic
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Readiness results:\n${result.stdout}

List Configured Models and Routes for LiteLLM Proxy `${LITELLM_SERVICE_NAME}`
    [Documentation]    Uses /v1/models and /v1/model/info to verify expected models are registered.
    [Tags]    Kubernetes    LiteLLM    models    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=list-litellm-models.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./list-litellm-models.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat litellm_models_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for models task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Configured models should be listed when authentication and routing are correct
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Model listing results:\n${result.stdout}

Check Optional Deep Model Health for LiteLLM Proxy `${LITELLM_SERVICE_NAME}`
    [Documentation]    When LITELLM_RUN_DEEP_HEALTH is true, calls GET /health with the master key to run upstream health checks (may incur provider cost).
    [Tags]    Kubernetes    LiteLLM    deep-health    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-litellm-deep-health.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-litellm-deep-health.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat litellm_deep_health_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for deep health task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Deep health should report healthy upstream endpoints when providers are reachable
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Deep health results:\n${result.stdout}

Check External Integration Service Health for LiteLLM Proxy `${LITELLM_SERVICE_NAME}`
    [Documentation]    Calls GET /health/services for configured integration names when LITELLM_INTEGRATION_SERVICES is set.
    [Tags]    Kubernetes    LiteLLM    integrations    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-litellm-integration-health.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-litellm-integration-health.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat litellm_integration_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for integration health task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Named integrations should report healthy status when configured
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Integration health results:\n${result.stdout}

Verify Kubernetes Service Reachability Context for `${LITELLM_SERVICE_NAME}`
    [Documentation]    Uses kubectl to confirm the Service and Endpoints exist and align with LITELLM_HTTP_PORT for correlating API failures with cluster networking.
    [Tags]    Kubernetes    LiteLLM    service    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=verify-litellm-k8s-service.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./verify-litellm-k8s-service.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat litellm_k8s_service_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for Kubernetes service task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Kubernetes Service should have endpoints and expected ports for client connectivity
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Kubernetes service verification:\n${result.stdout}


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ${litellm_master_key_provided}=    Set Variable    ${FALSE}
    TRY
        ${litellm_master_key}=    RW.Core.Import Secret    litellm_master_key
        ...    type=string
        ...    description=Optional LiteLLM master or admin API key for protected routes. When omitted the codebundle will try to derive it from a Kubernetes Secret in NAMESPACE.
        ...    pattern=\w*
        Set Suite Variable    ${litellm_master_key}    ${litellm_master_key}
        ${litellm_master_key_provided}=    Set Variable    ${TRUE}
    EXCEPT
        Log    litellm_master_key secret not provided; will try to derive from a Kubernetes Secret in the namespace.    INFO
        Set Suite Variable    ${litellm_master_key}    ${EMPTY}
    END
    Set Suite Variable    ${litellm_master_key_provided}    ${litellm_master_key_provided}
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Kubernetes context to use for kubectl-backed checks.
    ...    pattern=\w*
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=Namespace where the LiteLLM proxy runs.
    ...    pattern=\w*
    ${PROXY_BASE_URL}=    RW.Core.Import User Variable    PROXY_BASE_URL
    ...    type=string
    ...    description=Optional base URL for the LiteLLM HTTP API (for example http://my-litellm.my-ns.svc.cluster.local:4000). Leave empty to auto port-forward to the Service via kubectl.
    ...    pattern=.*
    ...    default=
    ${LITELLM_SERVICE_NAME}=    RW.Core.Import User Variable    LITELLM_SERVICE_NAME
    ...    type=string
    ...    description=Kubernetes Service name for the LiteLLM proxy.
    ...    pattern=\w*
    ${LITELLM_HTTP_PORT}=    RW.Core.Import User Variable    LITELLM_HTTP_PORT
    ...    type=string
    ...    description=Service port number for the proxy HTTP listener.
    ...    pattern=^\d+$
    ...    default=4000
    ${LITELLM_RUN_DEEP_HEALTH}=    RW.Core.Import User Variable    LITELLM_RUN_DEEP_HEALTH
    ...    type=string
    ...    description=Set to true to enable expensive GET /health upstream probes.
    ...    pattern=\w*
    ...    default=false
    ${LITELLM_INTEGRATION_SERVICES}=    RW.Core.Import User Variable    LITELLM_INTEGRATION_SERVICES
    ...    type=string
    ...    description=Comma-separated integration names for /health/services checks, or empty to skip.
    ...    pattern=.*
    ...    default=
    ${LITELLM_MASTER_KEY_SECRET_NAME}=    RW.Core.Import User Variable    LITELLM_MASTER_KEY_SECRET_NAME
    ...    type=string
    ...    description=Optional Kubernetes Secret name in NAMESPACE to read the master key from when the litellm_master_key secret is not provided. Leave empty to infer from the Pod env or auto-discover.
    ...    pattern=.*
    ...    default=
    ${LITELLM_MASTER_KEY_SECRET_KEY}=    RW.Core.Import User Variable    LITELLM_MASTER_KEY_SECRET_KEY
    ...    type=string
    ...    description=Optional data key within LITELLM_MASTER_KEY_SECRET_NAME. Leave empty to try common keys (masterkey, master_key, MASTER_KEY, LITELLM_MASTER_KEY).
    ...    pattern=.*
    ...    default=
    ${LITELLM_MASTER_KEY_INFER_FROM_POD}=    RW.Core.Import User Variable    LITELLM_MASTER_KEY_INFER_FROM_POD
    ...    type=string
    ...    description=When true (default), inspect the LiteLLM Pod env vars (e.g. LITELLM_MASTER_KEY) and follow any secretKeyRef to derive the key. Set to false to skip.
    ...    pattern=\w*
    ...    default=true
    ${LITELLM_MASTER_KEY_EXEC_FALLBACK}=    RW.Core.Import User Variable    LITELLM_MASTER_KEY_EXEC_FALLBACK
    ...    type=string
    ...    description=When true (default), fall back to `kubectl exec <pod> -- printenv LITELLM_MASTER_KEY` if Pod spec inspection cannot resolve the secretKeyRef (for example due to missing RBAC on the Secret, or env wired via envFrom.secretRef). Set to false to forbid exec.
    ...    pattern=\w*
    ...    default=true
    ${LITELLM_MASTER_KEY_SECRET_PATTERN}=    RW.Core.Import User Variable    LITELLM_MASTER_KEY_SECRET_PATTERN
    ...    type=string
    ...    description=Regex used to auto-discover a master key Secret by name as a last-resort fallback when Pod env inference does not find anything.
    ...    pattern=.*
    ...    default=litellm
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Kubernetes CLI binary to use.
    ...    enum=[kubectl,oc]
    ...    default=kubectl
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${PROXY_BASE_URL}    ${PROXY_BASE_URL}
    Set Suite Variable    ${LITELLM_SERVICE_NAME}    ${LITELLM_SERVICE_NAME}
    Set Suite Variable    ${LITELLM_HTTP_PORT}    ${LITELLM_HTTP_PORT}
    Set Suite Variable    ${LITELLM_RUN_DEEP_HEALTH}    ${LITELLM_RUN_DEEP_HEALTH}
    Set Suite Variable    ${LITELLM_INTEGRATION_SERVICES}    ${LITELLM_INTEGRATION_SERVICES}
    Set Suite Variable    ${LITELLM_MASTER_KEY_SECRET_NAME}    ${LITELLM_MASTER_KEY_SECRET_NAME}
    Set Suite Variable    ${LITELLM_MASTER_KEY_SECRET_KEY}    ${LITELLM_MASTER_KEY_SECRET_KEY}
    Set Suite Variable    ${LITELLM_MASTER_KEY_INFER_FROM_POD}    ${LITELLM_MASTER_KEY_INFER_FROM_POD}
    Set Suite Variable    ${LITELLM_MASTER_KEY_EXEC_FALLBACK}    ${LITELLM_MASTER_KEY_EXEC_FALLBACK}
    Set Suite Variable    ${LITELLM_MASTER_KEY_SECRET_PATTERN}    ${LITELLM_MASTER_KEY_SECRET_PATTERN}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    ${env}=    Create Dictionary
    ...    CONTEXT=${CONTEXT}
    ...    NAMESPACE=${NAMESPACE}
    ...    PROXY_BASE_URL=${PROXY_BASE_URL}
    ...    LITELLM_SERVICE_NAME=${LITELLM_SERVICE_NAME}
    ...    LITELLM_HTTP_PORT=${LITELLM_HTTP_PORT}
    ...    LITELLM_RUN_DEEP_HEALTH=${LITELLM_RUN_DEEP_HEALTH}
    ...    LITELLM_INTEGRATION_SERVICES=${LITELLM_INTEGRATION_SERVICES}
    ...    LITELLM_MASTER_KEY_SECRET_NAME=${LITELLM_MASTER_KEY_SECRET_NAME}
    ...    LITELLM_MASTER_KEY_SECRET_KEY=${LITELLM_MASTER_KEY_SECRET_KEY}
    ...    LITELLM_MASTER_KEY_INFER_FROM_POD=${LITELLM_MASTER_KEY_INFER_FROM_POD}
    ...    LITELLM_MASTER_KEY_EXEC_FALLBACK=${LITELLM_MASTER_KEY_EXEC_FALLBACK}
    ...    LITELLM_MASTER_KEY_SECRET_PATTERN=${LITELLM_MASTER_KEY_SECRET_PATTERN}
    ...    KUBERNETES_DISTRIBUTION_BINARY=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    KUBECONFIG=./${kubeconfig.key}
    Set Suite Variable    ${env}    ${env}
    Resolve LiteLLM Master Key

Resolve LiteLLM Master Key
    [Documentation]    Runs the master-key discovery script once so every task can reuse the cached value. Output is surfaced in the runbook report so operators can see where the key came from (or why it could not be derived).
    IF    ${litellm_master_key_provided}
        ${resolve_result}=    RW.CLI.Run Bash File
        ...    bash_file=resolve-litellm-master-key.sh
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        ...    secret__litellm_master_key=${litellm_master_key}
        ...    timeout_seconds=120
        ...    include_in_history=false
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=./resolve-litellm-master-key.sh
    ELSE
        ${resolve_result}=    RW.CLI.Run Bash File
        ...    bash_file=resolve-litellm-master-key.sh
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        ...    timeout_seconds=120
        ...    include_in_history=false
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=./resolve-litellm-master-key.sh
    END
    RW.Core.Add Pre To Report    Master key resolution:\n${resolve_result.stdout}
