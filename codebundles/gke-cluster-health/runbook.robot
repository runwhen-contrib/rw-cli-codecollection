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
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${gcp_credentials_json}    ${gcp_credentials_json}
    Set Suite Variable
    ...    ${env}
    ...    {"PATH": "$PATH:${OS_PATH}","CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials_json.key}", "GCP_PROJECT_ID":"${GCP_PROJECT_ID}"}

*** Tasks ***
Identify GKE Service Account Issues in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Checks for IAM Service Account issues that can affect Cluster functionality 
    [Tags]    gcloud    gke    gcp    access:read-only

    ${sa_check}=    RW.CLI.Run Bash File
    ...    bash_file=sa_check.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
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