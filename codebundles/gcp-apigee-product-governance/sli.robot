*** Settings ***
Documentation       Scores Apigee product/developer governance health as a value between 0 and 1 by averaging per-dimension binary checks (product access-control and quota, credential expiry, orphaned entitlements, developer status).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Apigee Product and Developer Governance
Metadata            Supports    GCP    Apigee    Governance

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization

*** Tasks ***
Score Apigee API Product Governance in `${APIGEE_ORG}`
    [Documentation]    Scores 1 if no API product permits auto-approval or has a missing/zero quota, 0 otherwise.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    security    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_api_products.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${count_output}=    RW.CLI.Run Cli
    ...    cmd=cat api_products_issues.json | jq length
    ...    env=${env}
    ${product_score}=    Evaluate    1 if int(${count_output.stdout}) == 0 else 0
    Set Suite Variable    ${product_score}
    RW.Core.Push Metric    ${count_output.stdout}    sub_name=product_issue_count
    RW.Core.Push Metric    ${product_score}    sub_name=product_governance

Score Apigee Consumer-Key Expiry in `${APIGEE_ORG}`
    [Documentation]    Scores 1 if no developer-app consumer key is expired or expiring within the warning window, 0 otherwise.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_app_credentials.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${count_output}=    RW.CLI.Run Cli
    ...    cmd=cat api_credentials_issues.json | jq length
    ...    env=${env}
    ${credential_score}=    Evaluate    1 if int(${count_output.stdout}) == 0 else 0
    Set Suite Variable    ${credential_score}
    RW.Core.Push Metric    ${count_output.stdout}    sub_name=expiring_key_count
    RW.Core.Push Metric    ${credential_score}    sub_name=credential_expiry

Score Apigee Orphaned/Unused Entitlements in `${APIGEE_ORG}`
    [Documentation]    Scores 1 if there are no orphaned API products, apps without consumer keys, or unused apps, 0 otherwise.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_orphaned_entitlements.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${count_output}=    RW.CLI.Run Cli
    ...    cmd=cat orphaned_entitlements_issues.json | jq length
    ...    env=${env}
    ${orphaned_score}=    Evaluate    1 if int(${count_output.stdout}) == 0 else 0
    Set Suite Variable    ${orphaned_score}
    RW.Core.Push Metric    ${count_output.stdout}    sub_name=orphaned_issue_count
    RW.Core.Push Metric    ${orphaned_score}    sub_name=orphaned_entitlements

Score Apigee Developer Status in `${APIGEE_ORG}`
    [Documentation]    Scores 1 if no developer is inactive/blocked with active apps and no app references a missing API product, 0 otherwise.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:state
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_developer_status.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${count_output}=    RW.CLI.Run Cli
    ...    cmd=cat developer_status_issues.json | jq length
    ...    env=${env}
    ${developer_score}=    Evaluate    1 if int(${count_output.stdout}) == 0 else 0
    Set Suite Variable    ${developer_score}
    RW.Core.Push Metric    ${count_output.stdout}    sub_name=developer_issue_count
    RW.Core.Push Metric    ${developer_score}    sub_name=developer_status

Generate Aggregate Apigee Governance Health Score for `${APIGEE_ORG}`
    [Documentation]    Averages the four governance dimensions into the final 0-to-1 health score.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:metrics
    ${health_score}=    Evaluate    (${product_score} + ${credential_score} + ${orphaned_score} + ${developer_score}) / 4
    ${health_score}=    Convert To Number    ${health_score}    2
    RW.Core.Add to Report    Apigee Product/Developer Governance Health Score: ${health_score} -- product: ${product_score}, credentials: ${credential_score}, orphaned: ${orphaned_score}, developer: ${developer_score}
    RW.Core.Push Metric    ${health_score}

*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account JSON key used to authenticate with gcloud and the Apigee management REST API.
    ...    pattern=\w*
    ...    example={"type": "service_account", "project_id": "my-project", ...}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP project that owns the Apigee organization.
    ...    pattern=[\w-]*
    ${APIGEE_ORG}=    RW.Core.Import User Variable    APIGEE_ORG
    ...    type=string
    ...    description=The Apigee organization name. If empty, discovered from GCP_PROJECT_ID.
    ...    default=${EMPTY}
    ...    pattern=[\w-]*
    ${APIPRODUCTS}=    RW.Core.Import User Variable    APIPRODUCTS
    ...    type=string
    ...    description=Comma-separated API product names to scope the analysis, or 'All'.
    ...    default=All
    ...    pattern=.*
    ${DEVELOPER_APPS}=    RW.Core.Import User Variable    DEVELOPER_APPS
    ...    type=string
    ...    description=Comma-separated developer app names to scope the analysis, or 'All'.
    ...    default=All
    ...    pattern=.*
    ${KEY_EXPIRY_WARNING_DAYS}=    RW.Core.Import User Variable    KEY_EXPIRY_WARNING_DAYS
    ...    type=string
    ...    description=Days before a consumer key expires to raise a warning.
    ...    default=30
    ...    pattern=^\d+$
    ${USAGE_LOOKBACK_DAYS}=    RW.Core.Import User Variable    USAGE_LOOKBACK_DAYS
    ...    type=string
    ...    description=Lookback window for Analytics usage cross-reference.
    ...    default=30
    ...    pattern=^\d+$
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${APIGEE_ORG}    ${APIGEE_ORG}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","APIGEE_ORG":"${APIGEE_ORG}","APIPRODUCTS":"${APIPRODUCTS}","DEVELOPER_APPS":"${DEVELOPER_APPS}","KEY_EXPIRY_WARNING_DAYS":"${KEY_EXPIRY_WARNING_DAYS}","USAGE_LOOKBACK_DAYS":"${USAGE_LOOKBACK_DAYS}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
