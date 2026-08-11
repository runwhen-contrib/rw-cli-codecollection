*** Settings ***
Documentation       Scores Apigee product/developer governance health as a value between 0 and 1 by averaging per-dimension binary checks (product access-control and quota, credential expiry, orphaned entitlements, developer status). A dimension whose underlying Apigee API calls could not be read scores 0, never 1 -- an unreadable organization must not look healthy.
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
    [Documentation]    Scores 1 if no API product permits auto-approval or has a missing/zero quota, 0 otherwise. Scores 0 if the API products could not be listed.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    security    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_api_products.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${product_score}    ${product_count}=    Score Dimension
    ...    api_products_issues.json    api_products_status.json
    Set Suite Variable    ${product_score}
    RW.Core.Push Metric    ${product_count}    sub_name=product_issue_count
    RW.Core.Push Metric    ${product_score}    sub_name=product_governance

Score Apigee Consumer-Key Expiry in `${APIGEE_ORG}`
    [Documentation]    Scores 1 if no developer-app consumer key is expired or expiring within the warning window, 0 otherwise. Scores 0 if the developer apps could not be listed.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_app_credentials.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${credential_score}    ${credential_count}=    Score Dimension
    ...    api_credentials_issues.json    api_credentials_status.json
    Set Suite Variable    ${credential_score}
    RW.Core.Push Metric    ${credential_count}    sub_name=expiring_key_count
    RW.Core.Push Metric    ${credential_score}    sub_name=credential_expiry

Score Apigee Orphaned/Unused Entitlements in `${APIGEE_ORG}`
    [Documentation]    Scores 1 if there are no orphaned API products, apps without consumer keys, or unused apps, 0 otherwise. Scores 0 if the entitlement surface could not be listed.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_orphaned_entitlements.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${orphaned_score}    ${orphaned_count}=    Score Dimension
    ...    orphaned_entitlements_issues.json    orphaned_entitlements_status.json
    Set Suite Variable    ${orphaned_score}
    RW.Core.Push Metric    ${orphaned_count}    sub_name=orphaned_issue_count
    RW.Core.Push Metric    ${orphaned_score}    sub_name=orphaned_entitlements

Score Apigee Developer Status in `${APIGEE_ORG}`
    [Documentation]    Scores 1 if no developer is inactive/blocked with active apps and no app references a missing API product, 0 otherwise. Scores 0 if the developers could not be listed.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:state
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_developer_status.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${developer_score}    ${developer_count}=    Score Dimension
    ...    developer_status_issues.json    developer_status_status.json
    Set Suite Variable    ${developer_score}
    RW.Core.Push Metric    ${developer_count}    sub_name=developer_issue_count
    RW.Core.Push Metric    ${developer_score}    sub_name=developer_status

Generate Aggregate Apigee Governance Health Score for `${APIGEE_ORG}`
    [Documentation]    Averages the four governance dimensions into the final 0-to-1 health score. Any dimension that could not be read contributes 0. A project positively determined to have no Apigee organization scores 1 and publishes apigee_present=0 so it can be filtered out.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:metrics
    # INTERIM: read applicability from the product dimension's sidecar. Every
    # check writes the same verdict because they all resolve the org the same
    # way. Compared with `==` rather than jq's `//`, which falls through on
    # `false` as well as null and would read a genuine false as "absent".
    ${applicable_output}=    RW.CLI.Run Cli
    ...    cmd=if [ -s api_products_status.json ]; then jq -r 'if has("applicable") then (.applicable | tostring) else "absent" end' api_products_status.json; else echo "absent"; fi
    ...    env=${env}
    ${not_applicable}=    Evaluate    """${applicable_output.stdout}""".strip() == "false"
    IF    ${not_applicable}
        ${reason_output}=    RW.CLI.Run Cli
        ...    cmd=jq -r '.reason // ""' api_products_status.json
        ...    env=${env}
        RW.Core.Add to Report    Apigee is not used in this project: ${reason_output.stdout}
        RW.Core.Add to Report    Scoring 1.0 by vacuity -- there is no Apigee entitlement surface here to be unhealthy. Filter on the apigee_present sub-metric to exclude these projects.
        RW.Core.Push Metric    ${0}    sub_name=apigee_present
        RW.Core.Push Metric    ${1.0}
    ELSE
        RW.Core.Push Metric    ${1}    sub_name=apigee_present
        ${health_score}=    Evaluate    (${product_score} + ${credential_score} + ${orphaned_score} + ${developer_score}) / 4
        ${health_score}=    Convert To Number    ${health_score}    2
        RW.Core.Add to Report    Apigee Product/Developer Governance Health Score: ${health_score} -- product: ${product_score}, credentials: ${credential_score}, orphaned: ${orphaned_score}, developer: ${developer_score}
        RW.Core.Add to Report    A dimension score of 0 with an issue count of -1 means the Apigee API could not be read for that dimension, not that it is unhealthy.
        RW.Core.Push Metric    ${health_score}
    END

*** Keywords ***
Score Dimension
    [Documentation]    Returns (score, issue_count) for one governance dimension.
    ...    A dimension is healthy (1) only when its check ran successfully AND
    ...    reported no issues. When the check could not read the Apigee API the
    ...    score is 0 and the issue count is reported as -1, so a blind run is
    ...    distinguishable from a clean one at the scoring layer rather than
    ...    silently indistinguishable from perfect health.
    ...
    ...    INTERIM: a project positively determined to have no Apigee
    ...    organization reports access_ok=true with applicable=false and scores
    ...    1 -- correct by vacuity. That branch is only ever reached on a
    ...    definite answer, never on a failed lookup.
    [Arguments]    ${issues_file}    ${status_file}
    ${status_output}=    RW.CLI.Run Cli
    ...    cmd=if [ -s "${status_file}" ]; then jq -r 'if .access_ok == true then "ok" else "fail" end' "${status_file}"; else echo "fail"; fi
    ...    env=${env}
    ${access_ok}=    Evaluate    """${status_output.stdout}""".strip() == "ok"
    IF    ${access_ok}
        ${count_output}=    RW.CLI.Run Cli
        ...    cmd=jq 'length' "${issues_file}"
        ...    env=${env}
        ${issue_count}=    Evaluate    int("""${count_output.stdout}""".strip())
        ${score}=    Evaluate    1 if ${issue_count} == 0 else 0
    ELSE
        Log    ${status_file} reports the Apigee API was unreadable; scoring this dimension 0.    WARN
        ${issue_count}=    Set Variable    ${-1}
        ${score}=    Set Variable    ${0}
    END
    RETURN    ${score}    ${issue_count}

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
    # No `|| true` here: if the service account cannot be activated every
    # subsequent API call fails, and that must surface as a failed dimension
    # rather than be swallowed into a perfect score.
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}"
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
