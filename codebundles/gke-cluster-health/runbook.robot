*** Settings ***
Documentation       Identify issues affecting GKE Clusters in a GCP Project
Metadata            Author    stewartshea
Metadata            Display Name    GKE Cluster Health
Metadata            Supports    GCP,GKE

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization


*** Keywords ***
Suite Initialization
    ${gcp_credentials_json}=    RW.Core.Import Secret    gcp_credentials_json
    ...    type=string
    ...    description=GCP service account json used to authenticate with GCP APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID", ... super secret stuff ...}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP Project ID to scope the API to.
    ...    pattern=\w*
    ...    example=myproject-ID
    ${CRITICAL_NAMESPACES}=    RW.Core.Import User Variable    CRITICAL_NAMESPACES
    ...    type=string
    ...    description=A comma separated list of namespaces which are critical. If pods are unhealthy in these namespaces, a severity 1 issue is raised. 
    ...    pattern=\w*
    ...    default=kube-system,flux-system,cert-manager
    ...    example=kube-system,flux-system,cert-manager
    ${OS_PATH}=    Get Environment Variable    PATH
    ${KUBECONFIG}=    Get Environment Variable     KUBECONFIG
    ${MAX_CPU_LIMIT_OVERCOMMIT}=     RW.Core.Import User Variable    MAX_CPU_LIMIT_OVERCOMMIT
    ...    type=string
    ...    description=The desired Maximum CPU Limits overcommitment factored into node recommendations.(e.g. 3=300% overcomitted)
    ...    pattern=\w*
    ...    default=3
    ...    example=3
    ${MAX_MEM_LIMIT_OVERCOMMIT}=    RW.Core.Import User Variable    MAX_MEM_LIMIT_OVERCOMMIT
    ...    type=string
    ...    description=The desired Maximum CPU Limits overcommitment factored into node recommendations.(e.g. 2=200% overcomitted)
    ...    pattern=\w*
    ...    default=2
    ...    example=2
    ${OPERATIONS_LOOKBACK_HOURS}=    RW.Core.Import User Variable    OPERATIONS_LOOKBACK_HOURS
    ...    type=string
    ...    description=The time (in hours) to fetch and analyze cluster operations. 
    ...    pattern=\w*
    ...    default=24
    ...    example=24
    ${OPERATIONS_STUCK_HOURS}=    RW.Core.Import User Variable    OPERATIONS_STUCK_HOURS
    ...    type=string
    ...    description=The amount of time (in hours) to declare an operation as stuck. 
    ...    pattern=\w*
    ...    default=2
    ...    example=2    
    ${LOOKBACK_WINDOW}=    RW.Core.Import User Variable    LOOKBACK_WINDOW
    ...    type=string
    ...    description=The time (in hours) to look back for node pool events and compute operations when checking node health. 
    ...    pattern=\w*
    ...    default=24
    ...    example=24
    ${NODE_HEALTH_LOOKBACK_HOURS}=    RW.Core.Normalize Lookback Window Str    ${LOOKBACK_WINDOW}    1
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${gcp_credentials_json}    ${gcp_credentials_json}
    Set Suite Variable
    ...    ${env}
    ...    {"CRITICAL_NAMESPACES":"${CRITICAL_NAMESPACES}","PATH": "$PATH:${OS_PATH}","CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials_json.key}", "GCP_PROJECT_ID":"${GCP_PROJECT_ID}", "KUBECONFIG":"${KUBECONFIG}", "MAX_CPU_LIMIT_OVERCOMMIT":"${MAX_CPU_LIMIT_OVERCOMMIT}", "MAX_MEM_LIMIT_OVERCOMMIT":"${MAX_MEM_LIMIT_OVERCOMMIT}","OP_LOOKBACK_HOURS":"${OPERATIONS_LOOKBACK_HOURS}", "STUCK_HOURS":"${OPERATIONS_STUCK_HOURS}", "NODE_HEALTH_LOOKBACK_HOURS":"${NODE_HEALTH_LOOKBACK_HOURS}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
*** Tasks ***
Identify GKE Service Account Issues in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Checks for IAM Service Account issues that can affect Cluster functionality 
    [Tags]    gcloud    gke    gcp    access:read-only

    ${sa_check}=    RW.CLI.Run Bash File
    ...    bash_file=sa_check.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    timeout_seconds=120
    RW.Core.Add Pre To Report    GKE Service Account Check Output:\n${sa_check.stdout}

    ${issues}=     RW.CLI.Run Cli
    ...    cmd=cat issues.json
    
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${issue}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=Service accounts should have there required permissions
            ...    actual=Service accounts are missing the required permissions
            ...    title= ${issue["title"]}
            ...    reproduce_hint=${sa_check.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_steps"]}
        END
    END

Fetch GKE Recommendations for GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Fetch and summarize GCP Recommendations for GKE Clusters
    [Tags]    recommendations    gcloud    gke    gcp    access:read-only

    ${gcp_recommendations}=    RW.CLI.Run Bash File
    ...    bash_file=gcp_recommendations.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    timeout_seconds=120
    ${report}=     RW.CLI.Run Cli
    ...    cmd=cat recommendations_report.txt
    RW.Core.Add Pre To Report    GKE Recommendation Output:\n${report.stdout}


    ${issues}=     RW.CLI.Run Cli
    ...    cmd=cat recommendations_issues.json
    
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=No recommendations should exist for GKE clusters in the location
            ...    actual=Recommendations exist for GKE clusters in the location
            ...    title= ${issue["title"]}
            ...    reproduce_hint=${gcp_recommendations.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_steps"]}
        END
    END

Fetch GKE Cluster Health for GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Using kubectl, fetch overall basic health of the cluster by checking unhealth pods and overutilized nodes. Useful when stackdriver is not available. Requires iam permissions to fetch cluster credentials with viewer rights. 
    [Tags]    health    crashloopbackoff    gcloud    gke    gcp    access:read-only

    ${cluster_health}=    RW.CLI.Run Bash File
    ...    bash_file=cluster_health.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    timeout_seconds=120
    ${report}=     RW.CLI.Run Cli
    ...    cmd=cat cluster_health_report.txt
    RW.Core.Add Pre To Report    Cluster Health Output:\n${report.stdout}

    ${issues}=     RW.CLI.Run Cli
    ...    cmd=cat cluster_health_issues.json
    
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=GKE Clusters should have available capacity and no pods in crashloopbackoff
            ...    actual=GKE Clusters have capcity or pod functionality issues
            ...    title= ${issue["title"]}
            ...    reproduce_hint=${cluster_health.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["suggested"]}
        END
    END

Check for Quota Related GKE Autoscaling Issues in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Ensure that GKE Autoscaling will not be blocked by Quota constraints
    [Tags]    quota    autoscaling    gcloud    gke    gcp    access:read-only

    ${quota_check}=    RW.CLI.Run Bash File
    ...    bash_file=quota_check.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    timeout_seconds=120
    ${report}=     RW.CLI.Run Cli
    ...    cmd=cat region_quota_report.txt
    RW.Core.Add Pre To Report    Cluster Health Output:\n${report.stdout}

    ${issues}=     RW.CLI.Run Cli
    ...    cmd=cat region_quota_issues.json
    
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=GKE Clusters should have available quota to scale
            ...    actual=GKE Clusters are limited by available quota
            ...    title= ${issue["title"]}
            ...    reproduce_hint=${quota_check.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["suggested"]}
        END
    END

Validate GKE Node Sizes for GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Analyse live pod requests/limits, node usage,  and propose suitable GKE node machine types.
    [Tags]    sizing    gke    gcloud    access:read-only    node    autoscale

    ${node_rec}=    RW.CLI.Run Cli
    ...    cmd=python3 gke_node_size.py
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    timeout_seconds=240

    ${issues}=     RW.CLI.Run Cli
    ...    cmd=cat node_size_issues.json
    
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=GKE Cluster should have available node capacity
            ...    actual=GKE Clusters are are capacity or need new nodes
            ...    title= ${issue["title"]}
            ...    reproduce_hint=${node_rec.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_steps"]}
        END
    END
    RW.Core.Add Pre To Report    Node‑size Recommendation Output:\n${node_rec.stdout}

Fetch GKE Cluster Operations for GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Fetches GKE Operations and identify stuck or failed tasks.
    [Tags]    sizing    gke    gcloud    access:read-only    cluster    operations

    ${ops_list}=    RW.CLI.Run Bash File
    ...    bash_file=cluster_operations.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    timeout_seconds=180

    ${ops_report}=     RW.CLI.Run Cli
    ...    cmd=cat cluster_operations_report.txt
    RW.Core.Add Pre To Report    Operations:\n${ops_report.stdout}

    ${issues}=     RW.CLI.Run Cli
    ...    cmd=cat cluster_operations_issues.json
    
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=GKE Cluster operations should not be stuck
            ...    actual=GKE Clusters operations might be stuck
            ...    title= ${issue["title"]}
            ...    reproduce_hint=${ops_list.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_steps"]}
        END
    END
    RW.Core.Add Pre To Report    Operations:\n${ops_list.stdout}

Check Node Pool Health for GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Performs comprehensive node pool health checking including instance group logs, compute operations, and Kubernetes events to surface hard-to-find issues like region exhaustion and quota blocking.
    [Tags]    nodepool    health    events    quota    exhaustion    gcloud    gke    gcp    access:read-only

    ${node_pool_health}=    RW.CLI.Run Bash File
    ...    bash_file=node_pool_health.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    timeout_seconds=300
    ${report}=     RW.CLI.Run Cli
    ...    cmd=cat node_pool_health_report.txt
    RW.Core.Add Pre To Report    Node Pool Health Output:\n${report.stdout}

    ${issues}=     RW.CLI.Run Cli
    ...    cmd=cat node_pool_health_issues.json
    
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=Node pools should be healthy without quota or resource exhaustion issues
            ...    actual=Node pools have critical issues including potential quota exhaustion or regional capacity problems
            ...    title= ${issue["title"]}
            ...    reproduce_hint=${node_pool_health.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_steps"]}
        END
    END
