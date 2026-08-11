*** Settings ***
Documentation       Measures the data-protection posture of Cloud Spanner databases by scoring backup recency, backup expiration, PITR configuration, deletion protection, IAM access, and encryption. Produces a value between 0 (completely failing) and 1 (fully passing).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Cloud Spanner Backup & Data Protection
Metadata            Supports    GCP,Spanner
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
    ...    description=GCP service account JSON key used to authenticate with GCP APIs. Requires Spanner Viewer and Spanner Backup Viewer roles.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID"}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP Project ID to scope the API to.
    ...    pattern=\w*
    ...    example=myproject-id
    ${BACKUP_RECENCY_THRESHOLD_HOURS}=    RW.Core.Import User Variable    BACKUP_RECENCY_THRESHOLD_HOURS
    ...    type=string
    ...    description=Max age (hours) of the most recent backup before an issue is raised.
    ...    pattern=\w*
    ...    default=24
    ${BACKUP_EXPIRY_WARNING_DAYS}=    RW.Core.Import User Variable    BACKUP_EXPIRY_WARNING_DAYS
    ...    type=string
    ...    description=Warn if a backup expires within this many days.
    ...    pattern=\w*
    ...    default=3
    ${PITR_MINIMUM_DAYS}=    RW.Core.Import User Variable    PITR_MINIMUM_DAYS
    ...    type=string
    ...    description=Minimum recommended point-in-time-recovery retention (days).
    ...    pattern=\w*
    ...    default=1
    ${REQUIRE_CMEK}=    RW.Core.Import User Variable    REQUIRE_CMEK
    ...    type=string
    ...    description=If 'true', flag databases not using customer-managed encryption.
    ...    pattern=\w*
    ...    default=false
    ...    enum=[true,false]
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${BACKUP_RECENCY_THRESHOLD_HOURS}    ${BACKUP_RECENCY_THRESHOLD_HOURS}
    Set Suite Variable    ${BACKUP_EXPIRY_WARNING_DAYS}    ${BACKUP_EXPIRY_WARNING_DAYS}
    Set Suite Variable    ${PITR_MINIMUM_DAYS}    ${PITR_MINIMUM_DAYS}
    Set Suite Variable    ${REQUIRE_CMEK}    ${REQUIRE_CMEK}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","CLOUDSDK_BILLING_QUOTA_PROJECT":"${GCP_PROJECT_ID}","BACKUP_RECENCY_THRESHOLD_HOURS":"${BACKUP_RECENCY_THRESHOLD_HOURS}","BACKUP_EXPIRY_WARNING_DAYS":"${BACKUP_EXPIRY_WARNING_DAYS}","PITR_MINIMUM_DAYS":"${PITR_MINIMUM_DAYS}","REQUIRE_CMEK":"${REQUIRE_CMEK}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}


*** Tasks ***
Score Cloud Spanner Backup Recency for `${GCP_PROJECT_ID}`
    [Documentation]    Scores backup existence and recency. Returns 1 if every database has a backup no older than the recency threshold.
    [Tags]    gcp    spanner    backup    recency    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_backup_recency.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat backup_recency_issues.json | jq length
    ...    env=${env}
    ${recency_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${recency_score}
    RW.Core.Push Metric    ${recency_score}    sub_name=backup_recency

Score Cloud Spanner Backup Expiration for `${GCP_PROJECT_ID}`
    [Documentation]    Scores backup expiration exposure. Returns 1 if no backup is expired or expiring within the warning window.
    [Tags]    gcp    spanner    backup    expiration    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_backup_expiration.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat backup_expiration_issues.json | jq length
    ...    env=${env}
    ${expiration_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${expiration_score}
    RW.Core.Push Metric    ${expiration_score}    sub_name=backup_expiration

Score Cloud Spanner PITR Configuration for `${GCP_PROJECT_ID}`
    [Documentation]    Scores point-in-time-recovery configuration. Returns 1 if every database meets the minimum PITR window.
    [Tags]    gcp    spanner    database    pitr    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_pitr_config.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat pitr_config_issues.json | jq length
    ...    env=${env}
    ${pitr_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${pitr_score}
    RW.Core.Push Metric    ${pitr_score}    sub_name=pitr_config

Score Cloud Spanner Deletion Protection for `${GCP_PROJECT_ID}`
    [Documentation]    Scores deletion protection coverage. Returns 1 if no instance or database has deletion protection disabled.
    [Tags]    gcp    spanner    instance    database    deletion-protection    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_deletion_protection.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat deletion_protection_issues.json | jq length
    ...    env=${env}
    ${deletion_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${deletion_score}
    RW.Core.Push Metric    ${deletion_score}    sub_name=deletion_protection

Score Cloud Spanner IAM Access Configuration for `${GCP_PROJECT_ID}`
    [Documentation]    Scores IAM exposure. Returns 1 if no public bindings or overly-permissive primitive roles are found.
    [Tags]    gcp    spanner    instance    database    iam    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_iam_access.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat iam_access_issues.json | jq length
    ...    env=${env}
    ${iam_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${iam_score}
    RW.Core.Push Metric    ${iam_score}    sub_name=iam_access

Score Cloud Spanner Encryption Configuration for `${GCP_PROJECT_ID}`
    [Documentation]    Scores encryption policy compliance. Returns 1 if no database violates the configured CMEK requirement.
    [Tags]    gcp    spanner    database    encryption    cmek    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_encryption_config.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat encryption_config_issues.json | jq length
    ...    env=${env}
    ${encryption_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${encryption_score}
    RW.Core.Push Metric    ${encryption_score}    sub_name=encryption_config

Generate Aggregate Cloud Spanner Data Protection Score for `${GCP_PROJECT_ID}`
    [Documentation]    Averages all sub-scores into a final 0-1 data-protection score for the project.
    [Tags]    gcp    spanner    data-protection    data:config    access:read-only
    ${protection_score}=    Evaluate    (${recency_score} + ${expiration_score} + ${pitr_score} + ${deletion_score} + ${iam_score} + ${encryption_score}) / 6
    ${health_score}=    Convert to Number    ${protection_score}    2
    RW.Core.Add to Report    Cloud Spanner Data Protection Score: ${health_score}
    RW.Core.Push Metric    ${health_score}
