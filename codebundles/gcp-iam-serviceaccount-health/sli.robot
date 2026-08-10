*** Settings ***
Documentation       Measures the health of GCP IAM service accounts by scoring privileged role assignments, key rotation, key count, disabled service accounts in use, and IAM policy drift. Produces a value between 0 (completely failing) and 1 (fully passing).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP IAM Service Account Health
Metadata            Supports    GCP,IAM,ServiceAccount,Security
Suite Setup         Suite Initialization
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections


*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account JSON key used to authenticate with GCP APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID"}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=GCP Project ID that houses the service accounts to inspect.
    ...    pattern=\w*
    ...    example=my-gcp-project
    ${SERVICE_ACCOUNT}=    RW.Core.Import User Variable    SERVICE_ACCOUNT
    ...    type=string
    ...    description=Optional email of a single service account to scope checks to. Empty means all service accounts in the project.
    ...    pattern=\w*
    ...    default=
    ${KEY_ROTATION_DAYS}=    RW.Core.Import User Variable    KEY_ROTATION_DAYS
    ...    type=string
    ...    description=Maximum allowed age of a service account key in days before rotation is flagged.
    ...    pattern=^\d+$
    ...    default=90
    ${MAX_KEYS_PER_SA}=    RW.Core.Import User Variable    MAX_KEYS_PER_SA
    ...    type=string
    ...    description=Maximum allowed number of active keys per service account before it is flagged.
    ...    pattern=^\d+$
    ...    default=5
    ${PRIVILEGED_ROLES}=    RW.Core.Import User Variable    PRIVILEGED_ROLES
    ...    type=string
    ...    description=Comma-separated list of roles considered high-privilege and worth flagging.
    ...    pattern=\w*
    ...    default=roles/owner,roles/editor
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${SERVICE_ACCOUNT}    ${SERVICE_ACCOUNT}
    Set Suite Variable    ${KEY_ROTATION_DAYS}    ${KEY_ROTATION_DAYS}
    Set Suite Variable    ${MAX_KEYS_PER_SA}    ${MAX_KEYS_PER_SA}
    Set Suite Variable    ${PRIVILEGED_ROLES}    ${PRIVILEGED_ROLES}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","SERVICE_ACCOUNT":"${SERVICE_ACCOUNT}","KEY_ROTATION_DAYS":"${KEY_ROTATION_DAYS}","MAX_KEYS_PER_SA":"${MAX_KEYS_PER_SA}","PRIVILEGED_ROLES":"${PRIVILEGED_ROLES}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}


*** Tasks ***
Score Service Account Privileged Role Assignments for `${GCP_PROJECT_ID}`
    [Documentation]    Scores privileged role assignments. Returns 1 if no service accounts hold high-privilege roles, 0 otherwise.
    [Tags]    gcp    iam    serviceaccount    security    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_privileged_roles.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat privileged_roles_issues.json | jq length
    ...    env=${env}
    ${priv_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${priv_score}
    RW.Core.Push Metric    ${priv_score}    sub_name=privileged_roles

Score Service Account Key Rotation for `${GCP_PROJECT_ID}`
    [Documentation]    Scores key rotation. Returns 1 if no keys exceed the rotation threshold, 0 otherwise.
    [Tags]    gcp    iam    serviceaccount    security    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_key_rotation.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat key_rotation_issues.json | jq length
    ...    env=${env}
    ${rotation_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${rotation_score}
    RW.Core.Push Metric    ${rotation_score}    sub_name=key_rotation

Score Service Account Key Count for `${GCP_PROJECT_ID}`
    [Documentation]    Scores key count hygiene. Returns 1 if no service accounts exceed the maximum key count, 0 otherwise.
    [Tags]    gcp    iam    serviceaccount    security    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_key_count.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat key_count_issues.json | jq length
    ...    env=${env}
    ${key_count_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${key_count_score}
    RW.Core.Push Metric    ${key_count_score}    sub_name=key_count

Score Disabled Service Accounts in Use for `${GCP_PROJECT_ID}`
    [Documentation]    Scores disabled service account hygiene. Returns 1 if no disabled service accounts are still referenced in IAM policies.
    [Tags]    gcp    iam    serviceaccount    security    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_disabled_service_accounts.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat disabled_sa_issues.json | jq length
    ...    env=${env}
    ${disabled_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${disabled_score}
    RW.Core.Push Metric    ${disabled_score}    sub_name=disabled_sa

Score Service Account IAM Policy Health for `${GCP_PROJECT_ID}`
    [Documentation]    Scores service account IAM policy health. Returns 1 if no drift (unused) service accounts are found in the policy analysis.
    [Tags]    gcp    iam    serviceaccount    security    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_service_account_policy.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat policy_analysis_issues.json | jq length
    ...    env=${env}
    ${policy_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${policy_score}
    RW.Core.Push Metric    ${policy_score}    sub_name=policy_health

Generate Aggregate Service Account Health Score for `${GCP_PROJECT_ID}`
    [Documentation]    Averages all sub-scores into a final 0-1 health score for the project's service accounts.
    [Tags]    gcp    iam    serviceaccount    health    data:metrics    access:read-only
    ${sa_health_score}=    Evaluate    (${priv_score} + ${rotation_score} + ${key_count_score} + ${disabled_score} + ${policy_score}) / 5
    ${health_score}=    Convert to Number    ${sa_health_score}    2
    RW.Core.Add to Report    Service Account Health Score: ${health_score}
    RW.Core.Push Metric    ${health_score}
