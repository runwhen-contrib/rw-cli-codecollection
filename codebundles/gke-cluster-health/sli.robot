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
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${gcp_credentials_json}    ${gcp_credentials_json}
    Set Suite Variable
    ...    ${env}
    ...    {"CRITICAL_NAMESPACES":"${CRITICAL_NAMESPACES}","PATH": "$PATH:${OS_PATH}","CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials_json.key}", "GCP_PROJECT_ID":"${GCP_PROJECT_ID}"}

*** Tasks ***
Identify GKE Service Account Issues in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Checks for IAM Service Account issues that can affect Cluster functionality 
    [Tags]    gcloud    gke    gcp    access:read-only

    ${sa_check}=    RW.CLI.Run Bash File
    ...    bash_file=sa_check.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
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

Fetch GKE Recommendations for GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Fetch and summarize GCP Recommendations for GKE Clusters
    [Tags]    recommendations    gcloud    gke    gcp    access:read-only

    ${gcp_recommendations}=    RW.CLI.Run Bash File
    ...    bash_file=gcp_recommendations.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
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

Fetch GKE Cluster Health for GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Using kubectl, fetch overall basic health of the cluster by checking unhealth pods and overutilized nodes. Useful when stackdriver is not available. Requires iam permissions to fetch cluster credentials with viewer rights. 
    [Tags]    health    crashloopbackoff    gcloud    gke    gcp    access:read-only

    ${cluster_health}=    RW.CLI.Run Bash File
    ...    bash_file=cluster_health.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    timeout_seconds=120

    ${issues}=     RW.CLI.Run Cli
    ...    cmd=cat cluster_health_issues.json
    
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    Set Global Variable     ${gke_cluster_health_core}    1
    IF    len(@{issue_list}) > 0
        FOR    ${item}    IN    @{issue_list}
            IF    ${item["severity"]} == 1 or ${item["severity"]} == 2
                Set Global Variable    ${gke_cluster_health_core}    0
                Exit For Loop
            ELSE IF    ${item["severity"]} > 2
                Set Global Variable    ${gke_cluster_health_core}    1
            END
        END
    END

Generate GKE Cluster Health Score
    ${gke_cluster_health_score}=      Evaluate  (${gke_sa_score} + ${gke_recommendations_score} + ${gke_cluster_health_core}) / 3
    ${health_score}=      Convert to Number    ${gke_cluster_health_score}  2
    RW.Core.Push Metric    ${health_score}