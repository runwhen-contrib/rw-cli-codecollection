*** Settings ***
Documentation       Validates SeaweedFS storage configuration health in a Kubernetes namespace by checking master leadership, volume slots, disk capacity, component connectivity, and S3 gateway operations.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Kubernetes SeaweedFS Storage Health Check
Metadata            Supports    Kubernetes SeaweedFS storage health S3

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.K8sHelper

Force Tags          Kubernetes    SeaweedFS    storage    health

Suite Setup         Suite Initialization


*** Tasks ***
List SeaweedFS Resources in Namespace `${NAMESPACE}`
    [Documentation]    Discovers SeaweedFS master, volume, filer, and S3 gateway workloads, services, and PVCs and surfaces missing components.
    [Tags]    Kubernetes    SeaweedFS    discovery    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=list-seaweedfs-resources.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" SEAWEEDFS_RELEASE_NAME="${SEAWEEDFS_RELEASE_NAME}" ./list-seaweedfs-resources.sh

    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat list_seaweedfs_resources_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for list resources task.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=SeaweedFS components should be discoverable in namespace `${NAMESPACE}`
            ...    actual=Resource discovery found gaps for release `${SEAWEEDFS_RELEASE_NAME}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    SeaweedFS resource discovery (stdout):
    RW.Core.Add Pre To Report    ${result.stdout}

Check SeaweedFS Workload Replica Health in Namespace `${NAMESPACE}`
    [Documentation]    Verifies StatefulSets and Deployments for SeaweedFS components have desired replicas ready and flags CrashLoopBackOff or pending pods.
    [Tags]    Kubernetes    SeaweedFS    workload    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-workload-health.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" SEAWEEDFS_RELEASE_NAME="${SEAWEEDFS_RELEASE_NAME}" ./check-workload-health.sh

    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat workload_health_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for workload health task.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=SeaweedFS workloads in `${NAMESPACE}` should have ready replicas matching desired counts
            ...    actual=Workload health checks reported problems for release `${SEAWEEDFS_RELEASE_NAME}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    SeaweedFS workload health (stdout):
    RW.Core.Add Pre To Report    ${result.stdout}

Check SeaweedFS Master Cluster Status in Namespace `${NAMESPACE}`
    [Documentation]    Queries master /cluster/status and /cluster/healthz to validate Raft leadership and master health endpoints.
    [Tags]    Kubernetes    SeaweedFS    master    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-master-cluster-status.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" SEAWEEDFS_MASTER_SERVICE="${SEAWEEDFS_MASTER_SERVICE}" ./check-master-cluster-status.sh

    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat master_cluster_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for master cluster task.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=SeaweedFS master should be healthy with an elected leader in `${NAMESPACE}`
            ...    actual=Master cluster API checks failed for context `${CONTEXT}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    SeaweedFS master cluster status (stdout):
    RW.Core.Add Pre To Report    ${result.stdout}

Check SeaweedFS Volume Slot Availability in Namespace `${NAMESPACE}`
    [Documentation]    Parses /dir/status topology to ensure free volume slots exist before workloads fail on allocation.
    [Tags]    Kubernetes    SeaweedFS    volumes    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-volume-slots.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" MIN_FREE_VOLUME_SLOTS="${MIN_FREE_VOLUME_SLOTS}" ./check-volume-slots.sh

    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat volume_slots_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for volume slots task.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=SeaweedFS should maintain at least `${MIN_FREE_VOLUME_SLOTS}` free volume slots in `${NAMESPACE}`
            ...    actual=Topology free slots are below threshold
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    SeaweedFS volume slot analysis (stdout):
    RW.Core.Add Pre To Report    ${result.stdout}

Check SeaweedFS Volume Server Disk Capacity in Namespace `${NAMESPACE}`
    [Documentation]    Inspects volume server /status and topology for disk usage, read-only volumes, and min-free-space threshold breaches.
    [Tags]    Kubernetes    SeaweedFS    capacity    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-volume-capacity.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" MIN_FREE_DISK_PERCENT="${MIN_FREE_DISK_PERCENT}" ./check-volume-capacity.sh

    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat volume_capacity_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for volume capacity task.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Volume servers in `${NAMESPACE}` should maintain at least `${MIN_FREE_DISK_PERCENT}` percent free disk
            ...    actual=Disk capacity or read-only volume signals were detected
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    SeaweedFS volume capacity analysis (stdout):
    RW.Core.Add Pre To Report    ${result.stdout}

Check SeaweedFS Writable Volume Layout in Namespace `${NAMESPACE}`
    [Documentation]    Evaluates /dir/status layouts for writable volume IDs and flags zero-writable or read-only placement problems.
    [Tags]    Kubernetes    SeaweedFS    layout    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-writable-layouts.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" ./check-writable-layouts.sh

    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat writable_layouts_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for writable layouts task.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=SeaweedFS writable layouts in `${NAMESPACE}` should have allocatable volumes for configured replication
            ...    actual=Layout evaluation found zero-writable or read-only volumes
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    SeaweedFS writable layout analysis (stdout):
    RW.Core.Add Pre To Report    ${result.stdout}

Check SeaweedFS Filer and Component Connectivity in Namespace `${NAMESPACE}`
    [Documentation]    Confirms filer health endpoints respond and volume servers appear registered in master topology.
    [Tags]    Kubernetes    SeaweedFS    connectivity    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-component-connectivity.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" SEAWEEDFS_FILER_SERVICE="${SEAWEEDFS_FILER_SERVICE}" ./check-component-connectivity.sh

    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat component_connectivity_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for connectivity task.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Filer and volume servers in `${NAMESPACE}` should be reachable and registered with master
            ...    actual=Component connectivity checks reported problems
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    SeaweedFS connectivity analysis (stdout):
    RW.Core.Add Pre To Report    ${result.stdout}

Verify SeaweedFS S3 Gateway Operations in Namespace `${NAMESPACE}`
    [Documentation]    Performs ListBuckets and put/get/delete of a temporary test object against the filer S3 endpoint when enabled.
    [Tags]    Kubernetes    SeaweedFS    S3    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=verify-s3-gateway.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    secret__seaweedfs_s3_credentials=${SEAWEEDFS_S3_CREDENTIALS}
    ...    timeout_seconds=240
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" S3_PROBE_BUCKET="${S3_PROBE_BUCKET}" SEAWEEDFS_S3_ENDPOINT="${SEAWEEDFS_S3_ENDPOINT}" ./verify-s3-gateway.sh

    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat s3_gateway_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for S3 gateway task.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=S3 gateway operations should succeed for SeaweedFS in `${NAMESPACE}` when S3 is enabled
            ...    actual=S3 probe reported failures or skipped checks
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    SeaweedFS S3 gateway probe (stdout):
    RW.Core.Add Pre To Report    ${result.stdout}

Check SeaweedFS Volume Configuration in Namespace `${NAMESPACE}`
    [Documentation]    Audits Helm-rendered workload commands, env, mounts, replication, and volume limits for misconfiguration.
    [Tags]    Kubernetes    SeaweedFS    config    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-volume-config.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" SEAWEEDFS_RELEASE_NAME="${SEAWEEDFS_RELEASE_NAME}" SEAWEEDFS_CHART="${SEAWEEDFS_CHART}" ./check-volume-config.sh

    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat volume_config_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for volume config task.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=SeaweedFS Helm workload configuration in `${NAMESPACE}` should match replication and persistence requirements
            ...    actual=Volume configuration audit reported problems
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    SeaweedFS volume configuration audit (stdout):
    RW.Core.Add Pre To Report    ${result.stdout}

Check SeaweedFS Garbage Collection and Compaction Signals in Namespace `${NAMESPACE}`
    [Documentation]    Reads master and volume Prometheus metrics for pick-for-write errors, crowded layouts, disk write failures, and delete-blocking read-only volumes.
    [Tags]    Kubernetes    SeaweedFS    gc    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-gc-compaction.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" SEAWEEDFS_RELEASE_NAME="${SEAWEEDFS_RELEASE_NAME}" SEAWEEDFS_CHART="${SEAWEEDFS_CHART}" MAX_PICK_FOR_WRITE_ERRORS="${MAX_PICK_FOR_WRITE_ERRORS}" MAX_VOLUME_DISK_ERRORS="${MAX_VOLUME_DISK_ERRORS}" ./check-gc-compaction.sh

    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat gc_compaction_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for GC/compaction task.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=SeaweedFS GC and compaction paths in `${NAMESPACE}` should not show sustained error counters
            ...    actual=GC/compaction metric checks reported problems
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    SeaweedFS GC/compaction analysis (stdout):
    RW.Core.Add Pre To Report    ${result.stdout}

Check SeaweedFS Capacity Projection in Namespace `${NAMESPACE}`
    [Documentation]    Evaluates slot and disk utilization headroom and estimates time-to-full when a prior capacity snapshot exists.
    [Tags]    Kubernetes    SeaweedFS    capacity    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-capacity-projection.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" SEAWEEDFS_RELEASE_NAME="${SEAWEEDFS_RELEASE_NAME}" SEAWEEDFS_CHART="${SEAWEEDFS_CHART}" CAPACITY_WARN_PERCENT="${CAPACITY_WARN_PERCENT}" MIN_PROJECTION_HOURS="${MIN_PROJECTION_HOURS}" ./check-capacity-projection.sh

    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat capacity_projection_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for capacity projection task.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=SeaweedFS capacity in `${NAMESPACE}` should maintain headroom below `${CAPACITY_WARN_PERCENT}` percent utilization
            ...    actual=Capacity projection checks reported risk of exhaustion
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    SeaweedFS capacity projection (stdout):
    RW.Core.Add Pre To Report    ${result.stdout}

Check SeaweedFS Known Version Issues in Namespace `${NAMESPACE}`
    [Documentation]    Matches the installed helm.sh/chart version against a curated catalog of SeaweedFS known issues and upgrade cautions.
    [Tags]    Kubernetes    SeaweedFS    version    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-known-issues.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" SEAWEEDFS_RELEASE_NAME="${SEAWEEDFS_RELEASE_NAME}" SEAWEEDFS_CHART="${SEAWEEDFS_CHART}" ./check-known-issues.sh

    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat known_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for known issues task.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Installed SeaweedFS chart version in `${NAMESPACE}` should not match known issue patterns
            ...    actual=Known-issue catalog matched this chart version
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    SeaweedFS known version issues (stdout):
    RW.Core.Add Pre To Report    ${result.stdout}


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=Kubernetes kubeconfig for cluster access.
    ...    pattern=\w*
    TRY
        ${SEAWEEDFS_S3_CREDENTIALS}=    RW.Core.Import Secret
        ...    seaweedfs_s3_credentials
        ...    type=string
        ...    description=Optional JSON S3 credentials for filer gateway probe.
        ...    pattern=.*
    EXCEPT
        Log    Optional seaweedfs_s3_credentials secret not provided.    WARN
        ${SEAWEEDFS_S3_CREDENTIALS}=    Set Variable    ${EMPTY}
    END
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Kubernetes CLI binary (kubectl or oc).
    ...    enum=[kubectl,oc]
    ...    default=kubectl
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Kubernetes context for the target cluster.
    ...    pattern=\w*
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=Namespace where SeaweedFS is deployed.
    ...    pattern=\w*
    ${SEAWEEDFS_RELEASE_NAME}=    RW.Core.Import User Variable    SEAWEEDFS_RELEASE_NAME
    ...    type=string
    ...    description=Helm release instance label (parent release for subchart installs).
    ...    default=
    ...    pattern=.*
    ${SEAWEEDFS_CHART}=    RW.Core.Import User Variable    SEAWEEDFS_CHART
    ...    type=string
    ...    description=Exact helm.sh/chart label for the SeaweedFS subchart (e.g. seaweedfs-4.25.0).
    ...    default=
    ...    pattern=.*
    ${SEAWEEDFS_MASTER_SERVICE}=    RW.Core.Import User Variable    SEAWEEDFS_MASTER_SERVICE
    ...    type=string
    ...    description=Override master service host:port when auto-discovery is insufficient.
    ...    default=
    ...    pattern=.*
    ${SEAWEEDFS_FILER_SERVICE}=    RW.Core.Import User Variable    SEAWEEDFS_FILER_SERVICE
    ...    type=string
    ...    description=Override filer service host:port when auto-discovery is insufficient.
    ...    default=
    ...    pattern=.*
    ${SEAWEEDFS_S3_ENDPOINT}=    RW.Core.Import User Variable    SEAWEEDFS_S3_ENDPOINT
    ...    type=string
    ...    description=Override S3 endpoint URL for gateway probe.
    ...    default=
    ...    pattern=.*
    ${MIN_FREE_VOLUME_SLOTS}=    RW.Core.Import User Variable    MIN_FREE_VOLUME_SLOTS
    ...    type=string
    ...    description=Minimum free volume slots required before raising an issue.
    ...    default=1
    ...    pattern=^\d+$
    ${MIN_FREE_DISK_PERCENT}=    RW.Core.Import User Variable    MIN_FREE_DISK_PERCENT
    ...    type=string
    ...    description=Minimum free disk percentage required on volume servers.
    ...    default=10
    ...    pattern=^\d+$
    ${S3_PROBE_BUCKET}=    RW.Core.Import User Variable    S3_PROBE_BUCKET
    ...    type=string
    ...    description=Existing bucket for S3 probe; temporary object prefix is used.
    ...    default=
    ...    pattern=.*
    ${CAPACITY_WARN_PERCENT}=    RW.Core.Import User Variable    CAPACITY_WARN_PERCENT
    ...    type=string
    ...    description=Slot or disk utilization percent that triggers capacity projection warnings.
    ...    default=80
    ...    pattern=^\d+$
    ${MIN_PROJECTION_HOURS}=    RW.Core.Import User Variable    MIN_PROJECTION_HOURS
    ...    type=string
    ...    description=Hours-until-full estimate that triggers slot exhaustion projection issues.
    ...    default=24
    ...    pattern=^\d+$
    ${MAX_PICK_FOR_WRITE_ERRORS}=    RW.Core.Import User Variable    MAX_PICK_FOR_WRITE_ERRORS
    ...    type=string
    ...    description=Master pick-for-write error counter threshold for GC/compaction checks.
    ...    default=100
    ...    pattern=^\d+$
    ${MAX_VOLUME_DISK_ERRORS}=    RW.Core.Import User Variable    MAX_VOLUME_DISK_ERRORS
    ...    type=string
    ...    description=Volume server disk write error counter threshold for GC/compaction checks.
    ...    default=50
    ...    pattern=^\d+$
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${SEAWEEDFS_S3_CREDENTIALS}    ${SEAWEEDFS_S3_CREDENTIALS}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${SEAWEEDFS_RELEASE_NAME}    ${SEAWEEDFS_RELEASE_NAME}
    Set Suite Variable    ${SEAWEEDFS_CHART}    ${SEAWEEDFS_CHART}
    Set Suite Variable    ${SEAWEEDFS_MASTER_SERVICE}    ${SEAWEEDFS_MASTER_SERVICE}
    Set Suite Variable    ${SEAWEEDFS_FILER_SERVICE}    ${SEAWEEDFS_FILER_SERVICE}
    Set Suite Variable    ${SEAWEEDFS_S3_ENDPOINT}    ${SEAWEEDFS_S3_ENDPOINT}
    Set Suite Variable    ${MIN_FREE_VOLUME_SLOTS}    ${MIN_FREE_VOLUME_SLOTS}
    Set Suite Variable    ${MIN_FREE_DISK_PERCENT}    ${MIN_FREE_DISK_PERCENT}
    Set Suite Variable    ${S3_PROBE_BUCKET}    ${S3_PROBE_BUCKET}
    Set Suite Variable    ${CAPACITY_WARN_PERCENT}    ${CAPACITY_WARN_PERCENT}
    Set Suite Variable    ${MIN_PROJECTION_HOURS}    ${MIN_PROJECTION_HOURS}
    Set Suite Variable    ${MAX_PICK_FOR_WRITE_ERRORS}    ${MAX_PICK_FOR_WRITE_ERRORS}
    Set Suite Variable    ${MAX_VOLUME_DISK_ERRORS}    ${MAX_VOLUME_DISK_ERRORS}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}","CONTEXT":"${CONTEXT}","NAMESPACE":"${NAMESPACE}","KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}","SEAWEEDFS_RELEASE_NAME":"${SEAWEEDFS_RELEASE_NAME}","SEAWEEDFS_CHART":"${SEAWEEDFS_CHART}","SEAWEEDFS_MASTER_SERVICE":"${SEAWEEDFS_MASTER_SERVICE}","SEAWEEDFS_FILER_SERVICE":"${SEAWEEDFS_FILER_SERVICE}","SEAWEEDFS_S3_ENDPOINT":"${SEAWEEDFS_S3_ENDPOINT}","MIN_FREE_VOLUME_SLOTS":"${MIN_FREE_VOLUME_SLOTS}","MIN_FREE_DISK_PERCENT":"${MIN_FREE_DISK_PERCENT}","S3_PROBE_BUCKET":"${S3_PROBE_BUCKET}","CAPACITY_WARN_PERCENT":"${CAPACITY_WARN_PERCENT}","MIN_PROJECTION_HOURS":"${MIN_PROJECTION_HOURS}","MAX_PICK_FOR_WRITE_ERRORS":"${MAX_PICK_FOR_WRITE_ERRORS}","MAX_VOLUME_DISK_ERRORS":"${MAX_VOLUME_DISK_ERRORS}"}

    RW.K8sHelper.Verify Cluster Connectivity
    ...    binary=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    context=${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
