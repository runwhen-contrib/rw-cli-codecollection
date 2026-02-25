*** Settings ***
Documentation       Identify issues affecting GKE Clusters in a GCP Project and creates a health score. A score of 1 is healthy, a score between 0 and 1 indicates unhealthy components. 
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
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
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
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"CRITICAL_NAMESPACES":"${CRITICAL_NAMESPACES}","PATH": "$PATH:${OS_PATH}","CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials.key}", "GCP_PROJECT_ID":"${GCP_PROJECT_ID}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}

*** Tasks ***
Identify GKE Service Account Issues in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Checks for IAM Service Account issues that can affect Cluster functionality 
    [Tags]    gcloud    gke    gcp    access:read-only    data:config

    ${sa_check}=    RW.CLI.Run Bash File
    ...    bash_file=sa_check.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=120

    ${issues}=     RW.CLI.Run Cli
    ...    cmd=cat issues.json
    
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    Set Global Variable     ${gke_sa_score}    1
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            IF    ${item["severity"]} == 1 or ${item["severity"]} == 2
                Set Global Variable    ${gke_sa_score}    0
                Exit For Loop
            ELSE IF    ${item["severity"]} > 2
                Set Global Variable    ${gke_sa_score}    1
            END
        END
    END
    RW.Core.Push Metric    ${gke_sa_score}    sub_name=service_accounts

Fetch GKE Recommendations for GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Fetch and summarize GCP Recommendations for GKE Clusters
    [Tags]    recommendations    gcloud    gke    gcp    access:read-only    data:config

    ${gcp_recommendations}=    RW.CLI.Run Bash File
    ...    bash_file=gcp_recommendations.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=120

    ${issues}=     RW.CLI.Run Cli
    ...    cmd=cat recommendations_issues.json
    
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    Set Global Variable     ${gke_recommendations_score}    1
    IF    len(@{issue_list}) > 0
        FOR    ${item}    IN    @{issue_list}
            IF    ${item["severity"]} == 1 or ${item["severity"]} == 2
                Set Global Variable    ${gke_recommendations_score}    0
                Exit For Loop
            ELSE IF    ${item["severity"]} > 2
                Set Global Variable    ${gke_recommendations_score}    1
            END
        END
    END
    RW.Core.Push Metric    ${gke_recommendations_score}    sub_name=recommendations

Fetch GKE Cluster Health for GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Using kubectl, fetch overall basic health of the cluster by checking unhealth pods and overutilized nodes. Useful when stackdriver is not available. Requires iam permissions to fetch cluster credentials with viewer rights. 
    [Tags]    health    crashloopbackoff    gcloud    gke    gcp    access:read-only    data:config

    ${cluster_health}=    RW.CLI.Run Bash File
    ...    bash_file=cluster_health.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=120

    ${issues}=     RW.CLI.Run Cli
    ...    cmd=cat cluster_health_issues.json
    
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    Set Global Variable     ${gke_cluster_health_score}    1
    IF    len(@{issue_list}) > 0
        FOR    ${item}    IN    @{issue_list}
            IF    ${item["severity"]} == 1 or ${item["severity"]} == 2
                Set Global Variable    ${gke_cluster_health_score}    0
                Exit For Loop
            ELSE IF    ${item["severity"]} > 2
                Set Global Variable    ${gke_cluster_health_score}    1
            END
        END
    END
    RW.Core.Push Metric    ${gke_cluster_health_score}    sub_name=cluster_health

Check for Quota Related GKE Autoscaling Issues in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Ensure that GKE Autoscaling will not be blocked by Quota constraints
    [Tags]    quota    autoscaling    gcloud    gke    gcp    access:read-only    data:config

    ${quota_check}=    RW.CLI.Run Bash File
    ...    bash_file=quota_check.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=120

    ${issues}=     RW.CLI.Run Cli
    ...    cmd=cat region_quota_issues.json
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json

    Set Global Variable     ${gke_quota_score}    1
    IF    len(@{issue_list}) > 0
        FOR    ${item}    IN    @{issue_list}
            IF    ${item["severity"]} == 1 or ${item["severity"]} == 2
                Set Global Variable    ${gke_quota_score}    0
                Exit For Loop
            ELSE IF    ${item["severity"]} > 2
                Set Global Variable    ${gke_quota_score}    1
            END
        END
    END    
    RW.Core.Push Metric    ${gke_quota_score}    sub_name=quota_limits

Quick Node Instance Group Health Check for GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Fast detection of critical node instance group health issues like quota exhaustion and provisioning failures
    [Tags]    nodepool    instances    quota    gcloud    gke    gcp    access:read-only    data:config

    ${instance_health_check}=    RW.CLI.Run Bash File
    ...    bash_file=node_pool_health.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=45

    ${issues}=     RW.CLI.Run Cli
    ...    cmd=cat node_pool_health_issues.json
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json

    Set Global Variable     ${gke_node_instance_score}    1
    IF    len(@{issue_list}) > 0
        FOR    ${item}    IN    @{issue_list}
            IF    ${item["severity"]} == 1 or ${item["severity"]} == 2
                Set Global Variable    ${gke_node_instance_score}    0
                Exit For Loop
            ELSE IF    ${item["severity"]} > 2
                Set Global Variable    ${gke_node_instance_score}    1
            END
        END
    END
    RW.Core.Push Metric    ${gke_node_instance_score}    sub_name=node_instances

Generate GKE Cluster Health Score
    ${gke_total_health_score}=      Evaluate  (${gke_sa_score} + ${gke_recommendations_score} + ${gke_cluster_health_score} +${gke_quota_score} + ${gke_node_instance_score}) / 5
    ${health_score}=      Convert to Number    ${gke_total_health_score}  2
    RW.Core.Push Metric    ${health_score}