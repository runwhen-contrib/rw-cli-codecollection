*** Settings ***
Documentation       Checks the overall health of an OpenObserve deployment running in Kubernetes: workload/pod health, API reachability, and - because storage cannot be inspected from inside the container - storage/ingestion/cluster state queried through the OpenObserve HTTP API using credentials resolved from Kubernetes secrets.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Kubernetes OpenObserve Health Check
Metadata            Supports    Kubernetes    AKS    EKS    GKE    OpenShift    OpenObserve    HTTP

Force Tags          Kubernetes    OpenObserve    HTTP    health    availability

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
List OpenObserve Resources in Namespace `${NAMESPACE}`
    [Documentation]    Discovers the OpenObserve workload(s), Service, PVCs, Secret(s) and ConfigMap(s) in the namespace and adds a topology summary to the report. Raises an issue when no OpenObserve resources are found.
    [Tags]    Kubernetes    OpenObserve    discovery    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=list-openobserve-resources.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" OBJECT_NAME="${OBJECT_NAME}" ./list-openobserve-resources.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat openobserve_resources_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for resource discovery task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=OpenObserve workloads should be discoverable in namespace `${NAMESPACE}`
            ...    actual=Resource discovery found no OpenObserve workloads in namespace `${NAMESPACE}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    OpenObserve resource discovery results:\n${result.stdout}

Check OpenObserve Workload Replica Health in Namespace `${NAMESPACE}`
    [Documentation]    Compares ready vs. desired replicas for each OpenObserve Deployment/StatefulSet and flags workloads that are not fully ready or scaled to zero.
    [Tags]    Kubernetes    OpenObserve    replicas    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-openobserve-replica-health.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" ./check-openobserve-replica-health.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat openobserve_replica_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for replica health task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=OpenObserve workloads should have all desired replicas ready
            ...    actual=One or more OpenObserve workloads are not fully ready or scaled to zero
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    OpenObserve workload replica health:\n${result.stdout}

Check OpenObserve Pod Stability in Namespace `${NAMESPACE}`
    [Documentation]    Inspects OpenObserve Pods for non-Running phases, CrashLoopBackOff, failed readiness, and high restart counts to surface instability before it becomes an outage.
    [Tags]    Kubernetes    OpenObserve    pod    crashloop    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-openobserve-pod-health.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" OBJECT_NAME="${OBJECT_NAME}" ./check-openobserve-pod-health.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat openobserve_pod_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for pod stability task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=OpenObserve Pods should be Running and stable with low restart counts
            ...    actual=OpenObserve Pods are unstable (CrashLoopBackOff, not ready, or high restarts)
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    OpenObserve pod stability analysis:\n${result.stdout}

Check OpenObserve API Health in Namespace `${NAMESPACE}`
    [Documentation]    Resolves the admin credentials and OpenObserve Base URL (auto port-forward to svc/${OPENOBSERVE_SERVICE_NAME} when not provided) and GETs the health/status endpoints, flagging non-200 responses and authentication failures.
    [Tags]    Kubernetes    OpenObserve    api    health    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-openobserve-api-health.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" OPENOBSERVE_BASE_URL="${OPENOBSERVE_BASE_URL}" ./check-openobserve-api-health.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat openobserve_api_health_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for API health task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=OpenObserve API health endpoint should return HTTP 200 with valid authentication
            ...    actual=OpenObserve API health check failed (non-200 or authentication failure)
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    OpenObserve API health results:\n${result.stdout}

Check OpenObserve Storage Metrics via API in Namespace `${NAMESPACE}`
    [Documentation]    Calls the OpenObserve storage_metrics API to detect S3 storage access failures, WAL/parquet file growth, and upload issues. This is the source of truth for storage health since storage is not observable from inside the container.
    [Tags]    Kubernetes    OpenObserve    storage    metrics    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-openobserve-storage-metrics.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" STORAGE_S3_FAILURE_THRESHOLD="${STORAGE_S3_FAILURE_THRESHOLD}" ./check-openobserve-storage-metrics.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat openobserve_storage_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for storage metrics task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=OpenObserve storage should report no S3 access failures above threshold
            ...    actual=OpenObserve storage_metrics reports S3 access failures above threshold
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    OpenObserve storage metrics results:\n${result.stdout}

Check OpenObserve Cluster Processing Health in Namespace `${NAMESPACE}`
    [Documentation]    Queries the OpenObserve cluster_info endpoint for per-node pending compaction jobs and flags nodes with a compaction backlog above threshold, indicating storage lifecycle work is not keeping up.
    [Tags]    Kubernetes    OpenObserve    cluster    compaction    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-openobserve-cluster-health.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" CLUSTER_PENDING_JOBS_THRESHOLD="${CLUSTER_PENDING_JOBS_THRESHOLD}" ./check-openobserve-cluster-health.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat openobserve_cluster_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for cluster health task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=OpenObserve nodes should have no pending compaction backlog above threshold
            ...    actual=One or more OpenObserve nodes have a pending compaction backlog
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    OpenObserve cluster processing results:\n${result.stdout}

Check OpenObserve Ingestion Queue Health in Namespace `${NAMESPACE}`
    [Documentation]    Queries the OpenObserve queues endpoint and flags memory/disk queue key growth that signals ingestion is backing up and data may be delayed or dropped.
    [Tags]    Kubernetes    OpenObserve    ingestion    queue    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-openobserve-queue-health.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" INGESTION_QUEUE_KEY_THRESHOLD="${INGESTION_QUEUE_KEY_THRESHOLD}" ./check-openobserve-queue-health.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat openobserve_queue_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for ingestion queue task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=OpenObserve ingestion queues should stay below the key-count threshold
            ...    actual=OpenObserve ingestion queues are backing up above the threshold
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    OpenObserve ingestion queue results:\n${result.stdout}

Check OpenObserve Storage Configuration in Namespace `${NAMESPACE}`
    [Documentation]    Reads the OpenObserve workload env for storage topology (ZO_LOCAL_MODE, ZO_DATA_DIR, ZO_S3_*) and validates that S3 settings exist when local mode is disabled.
    [Tags]    Kubernetes    OpenObserve    storage    config    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-openobserve-storage-config.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" OBJECT_NAME="${OBJECT_NAME}" ./check-openobserve-storage-config.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat openobserve_storage_config_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for storage config task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=OpenObserve storage configuration should match the deployment mode (local vs S3)
            ...    actual=OpenObserve storage configuration is incomplete or inconsistent
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    OpenObserve storage configuration audit:\n${result.stdout}

Check OpenObserve PVC Capacity in Namespace `${NAMESPACE}`
    [Documentation]    Lists the PVCs backing OpenObserve (capacity, status, reclaim policy) and flags unbound volumes or volumes approaching capacity using kubectl-level data only, keeping the container-access constraint.
    [Tags]    Kubernetes    OpenObserve    pvc    capacity    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-openobserve-pvc-capacity.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" PVC_USAGE_THRESHOLD_PERCENT="${PVC_USAGE_THRESHOLD_PERCENT}" ./check-openobserve-pvc-capacity.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat openobserve_pvc_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for PVC capacity task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=OpenObserve PVCs should be bound and have adequate capacity headroom
            ...    actual=One or more OpenObserve PVCs are unbound or approaching capacity
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    OpenObserve PVC capacity report:\n${result.stdout}


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ${openobserve_credentials_provided}=    Set Variable    ${FALSE}
    TRY
        ${openobserve_credentials}=    RW.Core.Import Secret
        ...    openobserve_credentials
        ...    type=string
        ...    description=Optional RunWhen secret with the OpenObserve admin credentials as JSON {username|email, password}. When omitted the codebundle tries to derive them from a Kubernetes Secret in NAMESPACE or from the workload Pod env.
        ...    pattern=.*
        Set Suite Variable    ${openobserve_credentials}    ${openobserve_credentials}
        ${openobserve_credentials_provided}=    Set Variable    ${TRUE}
    EXCEPT
        Log    openobserve_credentials secret not provided; will try to derive from a Kubernetes Secret or workload env.    INFO
        Set Suite Variable    ${openobserve_credentials}    ${EMPTY}
    END
    Set Suite Variable    ${openobserve_credentials_provided}    ${openobserve_credentials_provided}
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Kubernetes context to use for kubectl-backed checks.
    ...    pattern=\w*
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=Namespace where OpenObserve runs.
    ...    pattern=\w*
    ${OBJECT_NAME}=    RW.Core.Import User Variable    OBJECT_NAME
    ...    type=string
    ...    description=OpenObserve workload name (Deployment or StatefulSet) this SLX monitors. Used to scope pod and credential discovery.
    ...    pattern=\w*
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Kubernetes CLI binary to use.
    ...    enum=[kubectl,oc]
    ...    default=kubectl
    ${OPENOBSERVE_SERVICE_NAME}=    RW.Core.Import User Variable    OPENOBSERVE_SERVICE_NAME
    ...    type=string
    ...    description=Kubernetes Service name exposing the OpenObserve HTTP port. Auto-discovered from a Service whose name contains 'openobserve' when empty.
    ...    pattern=.*
    ...    default=
    ${OPENOBSERVE_HTTP_PORT}=    RW.Core.Import User Variable    OPENOBSERVE_HTTP_PORT
    ...    type=string
    ...    description=OpenObserve HTTP port on the Service.
    ...    pattern=^\d+$
    ...    default=5080
    ${OPENOBSERVE_LOCAL_PORT}=    RW.Core.Import User Variable    OPENOBSERVE_LOCAL_PORT
    ...    type=string
    ...    description=Local port used when auto port-forwarding.
    ...    pattern=^\d+$
    ...    default=5080
    ${OPENOBSERVE_ORGANIZATION}=    RW.Core.Import User Variable    OPENOBSERVE_ORGANIZATION
    ...    type=string
    ...    description=OpenObserve organization used in the API path (/api/{org}/...).
    ...    pattern=\w*
    ...    default=default
    ${OPENOBSERVE_BASE_URL}=    RW.Core.Import User Variable    OPENOBSERVE_BASE_URL
    ...    type=string
    ...    description=Optional direct Base URL (e.g. http://openobserve.<ns>.svc.cluster.local:5080). Leave empty to auto start kubectl port-forward to svc/${OPENOBSERVE_SERVICE_NAME} on ${OPENOBSERVE_HTTP_PORT}.
    ...    pattern=.*
    ...    default=
    ${OPENOBSERVE_API_TIMEOUT}=    RW.Core.Import User Variable    OPENOBSERVE_API_TIMEOUT
    ...    type=string
    ...    description=Timeout in seconds for API curl calls.
    ...    pattern=^\d+$
    ...    default=25
    ${OPENOBSERVE_PF_WAIT_SECS}=    RW.Core.Import User Variable    OPENOBSERVE_PF_WAIT_SECS
    ...    type=string
    ...    description=Max seconds to wait for the automatic kubectl port-forward to become ready.
    ...    pattern=^\d+$
    ...    default=15
    ${OPENOBSERVE_CREDENTIAL_SECRET_NAME}=    RW.Core.Import User Variable    OPENOBSERVE_CREDENTIAL_SECRET_NAME
    ...    type=string
    ...    description=Optional Kubernetes Secret name holding the OpenObserve credentials. When empty, infers from the workload Pod env (ROOT_USER_EMAIL/ROOT_USER_PASSWORD or ZO_ROOT_USER_*), following secretKeyRef.
    ...    pattern=.*
    ...    default=
    ${OPENOBSERVE_CREDENTIAL_USER_KEY}=    RW.Core.Import User Variable    OPENOBSERVE_CREDENTIAL_USER_KEY
    ...    type=string
    ...    description=Secret data key for the API username; auto-probes ROOT_USER_EMAIL, ZO_ROOT_USER_EMAIL, ROOT_USER_NAME when empty.
    ...    pattern=.*
    ...    default=
    ${OPENOBSERVE_CREDENTIAL_PASSWORD_KEY}=    RW.Core.Import User Variable    OPENOBSERVE_CREDENTIAL_PASSWORD_KEY
    ...    type=string
    ...    description=Secret data key for the API password; auto-probes ROOT_USER_PASSWORD, ZO_ROOT_USER_PASSWORD when empty.
    ...    pattern=.*
    ...    default=
    ${OPENOBSERVE_ALLOW_EXEC}=    RW.Core.Import User Variable    OPENOBSERVE_ALLOW_EXEC
    ...    type=string
    ...    description=Set to 'true' to allow kubectl exec <pod> -- printenv as a last-resort credential fallback.
    ...    pattern=\w*
    ...    default=false
    ${OPENOBSERVE_POD_RESTART_THRESHOLD}=    RW.Core.Import User Variable    OPENOBSERVE_POD_RESTART_THRESHOLD
    ...    type=string
    ...    description=Minimum container restart count that flags an unstable OpenObserve Pod.
    ...    pattern=^\d+$
    ...    default=5
    ${STORAGE_S3_FAILURE_THRESHOLD}=    RW.Core.Import User Variable    STORAGE_S3_FAILURE_THRESHOLD
    ...    type=string
    ...    description=Max s3_access_failures per storage_metrics sample before raising an issue.
    ...    pattern=^\d+$
    ...    default=10
    ${INGESTION_QUEUE_KEY_THRESHOLD}=    RW.Core.Import User Variable    INGESTION_QUEUE_KEY_THRESHOLD
    ...    type=string
    ...    description=Max total (mem + disk) queue keys before flagging an ingestion backlog.
    ...    pattern=^\d+$
    ...    default=100000
    ${CLUSTER_PENDING_JOBS_THRESHOLD}=    RW.Core.Import User Variable    CLUSTER_PENDING_JOBS_THRESHOLD
    ...    type=string
    ...    description=Max pending compaction jobs per node before flagging cluster processing backlog.
    ...    pattern=^\d+$
    ...    default=100
    ${PVC_USAGE_THRESHOLD_PERCENT}=    RW.Core.Import User Variable    PVC_USAGE_THRESHOLD_PERCENT
    ...    type=string
    ...    description=PVC capacity warning threshold (percent).
    ...    pattern=^\d+$
    ...    default=80
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${OBJECT_NAME}    ${OBJECT_NAME}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${OPENOBSERVE_SERVICE_NAME}    ${OPENOBSERVE_SERVICE_NAME}
    Set Suite Variable    ${OPENOBSERVE_HTTP_PORT}    ${OPENOBSERVE_HTTP_PORT}
    Set Suite Variable    ${OPENOBSERVE_LOCAL_PORT}    ${OPENOBSERVE_LOCAL_PORT}
    Set Suite Variable    ${OPENOBSERVE_ORGANIZATION}    ${OPENOBSERVE_ORGANIZATION}
    Set Suite Variable    ${OPENOBSERVE_BASE_URL}    ${OPENOBSERVE_BASE_URL}
    Set Suite Variable    ${OPENOBSERVE_API_TIMEOUT}    ${OPENOBSERVE_API_TIMEOUT}
    Set Suite Variable    ${OPENOBSERVE_PF_WAIT_SECS}    ${OPENOBSERVE_PF_WAIT_SECS}
    Set Suite Variable    ${OPENOBSERVE_CREDENTIAL_SECRET_NAME}    ${OPENOBSERVE_CREDENTIAL_SECRET_NAME}
    Set Suite Variable    ${OPENOBSERVE_CREDENTIAL_USER_KEY}    ${OPENOBSERVE_CREDENTIAL_USER_KEY}
    Set Suite Variable    ${OPENOBSERVE_CREDENTIAL_PASSWORD_KEY}    ${OPENOBSERVE_CREDENTIAL_PASSWORD_KEY}
    Set Suite Variable    ${OPENOBSERVE_ALLOW_EXEC}    ${OPENOBSERVE_ALLOW_EXEC}
    Set Suite Variable    ${OPENOBSERVE_POD_RESTART_THRESHOLD}    ${OPENOBSERVE_POD_RESTART_THRESHOLD}
    Set Suite Variable    ${STORAGE_S3_FAILURE_THRESHOLD}    ${STORAGE_S3_FAILURE_THRESHOLD}
    Set Suite Variable    ${INGESTION_QUEUE_KEY_THRESHOLD}    ${INGESTION_QUEUE_KEY_THRESHOLD}
    Set Suite Variable    ${CLUSTER_PENDING_JOBS_THRESHOLD}    ${CLUSTER_PENDING_JOBS_THRESHOLD}
    Set Suite Variable    ${PVC_USAGE_THRESHOLD_PERCENT}    ${PVC_USAGE_THRESHOLD_PERCENT}
    ${env}=    Create Dictionary
    ...    CONTEXT=${CONTEXT}
    ...    NAMESPACE=${NAMESPACE}
    ...    OBJECT_NAME=${OBJECT_NAME}
    ...    KUBERNETES_DISTRIBUTION_BINARY=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    OPENOBSERVE_SERVICE_NAME=${OPENOBSERVE_SERVICE_NAME}
    ...    OPENOBSERVE_HTTP_PORT=${OPENOBSERVE_HTTP_PORT}
    ...    OPENOBSERVE_LOCAL_PORT=${OPENOBSERVE_LOCAL_PORT}
    ...    OPENOBSERVE_ORGANIZATION=${OPENOBSERVE_ORGANIZATION}
    ...    OPENOBSERVE_BASE_URL=${OPENOBSERVE_BASE_URL}
    ...    OPENOBSERVE_API_TIMEOUT=${OPENOBSERVE_API_TIMEOUT}
    ...    OPENOBSERVE_PF_WAIT_SECS=${OPENOBSERVE_PF_WAIT_SECS}
    ...    OPENOBSERVE_CREDENTIAL_SECRET_NAME=${OPENOBSERVE_CREDENTIAL_SECRET_NAME}
    ...    OPENOBSERVE_CREDENTIAL_USER_KEY=${OPENOBSERVE_CREDENTIAL_USER_KEY}
    ...    OPENOBSERVE_CREDENTIAL_PASSWORD_KEY=${OPENOBSERVE_CREDENTIAL_PASSWORD_KEY}
    ...    OPENOBSERVE_ALLOW_EXEC=${OPENOBSERVE_ALLOW_EXEC}
    ...    OPENOBSERVE_POD_RESTART_THRESHOLD=${OPENOBSERVE_POD_RESTART_THRESHOLD}
    ...    STORAGE_S3_FAILURE_THRESHOLD=${STORAGE_S3_FAILURE_THRESHOLD}
    ...    INGESTION_QUEUE_KEY_THRESHOLD=${INGESTION_QUEUE_KEY_THRESHOLD}
    ...    CLUSTER_PENDING_JOBS_THRESHOLD=${CLUSTER_PENDING_JOBS_THRESHOLD}
    ...    PVC_USAGE_THRESHOLD_PERCENT=${PVC_USAGE_THRESHOLD_PERCENT}
    ...    KUBECONFIG=./${kubeconfig.key}
    Set Suite Variable    ${env}    ${env}
    Resolve OpenObserve Credentials

Resolve OpenObserve Credentials
    [Documentation]    Runs the credential discovery script once so every task can reuse the cached value. Output is surfaced in the runbook report so operators can see where the credentials came from (or why they could not be derived).
    IF    ${openobserve_credentials_provided}
        ${resolve_result}=    RW.CLI.Run Bash File
        ...    bash_file=resolve-openobserve-credentials.sh
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        ...    secret__openobserve_credentials=${openobserve_credentials}
        ...    timeout_seconds=120
        ...    include_in_history=false
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=./resolve-openobserve-credentials.sh
    ELSE
        ${resolve_result}=    RW.CLI.Run Bash File
        ...    bash_file=resolve-openobserve-credentials.sh
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        ...    timeout_seconds=120
        ...    include_in_history=false
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=./resolve-openobserve-credentials.sh
    END
    RW.Core.Add Pre To Report    OpenObserve credential resolution:\n${resolve_result.stdout}