*** Settings ***
Documentation       Measures the health of a GCP Compute Engine instance group by scoring member health, autoscaling, patch compliance, and utilization. Produces a value between 0 (completely failing) and 1 (fully passing).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Compute Engine Instance Group Health
Metadata            Supports    GCP,Compute Engine,Instance Groups,Compute

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization

Force Tags          GCP    Compute Engine    Instance Group    Health

*** Tasks ***
Score Instance Group Member Health for `${INSTANCE_GROUP_NAME}`
    [Documentation]    Scores 1 if all member instances of the group are healthy (no degraded/stopped/recreating instances).
    [Tags]    gcloud    gcp    instancegroup    access:read-only    data:metrics
    ${member_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_group_member_health.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${member_issues}=    RW.CLI.Run Cli
    ...    cmd=cat group_member_health_issues.json | jq '[.[] | select(.severity <= 3)] | length'
    ...    env=${env}
    # Severity 1 is the most severe, so issues at or above severity 3 are the
    # ones that lower the score. Anything other than a literal "0" - including
    # empty output from a check that failed to write its file - scores 0, so a
    # broken check can never be reported as healthy.
    ${member_score}=    Evaluate    1 if """${member_issues.stdout}""".strip() == "0" else 0
    Set Global Variable    ${member_score}
    RW.Core.Push Metric    ${member_score}    sub_name=member_health

Score Instance Group Autoscaling and Capacity for `${INSTANCE_GROUP_NAME}`
    [Documentation]    Scores 1 if the managed group can scale to meet demand within its autoscaler bounds.
    [Tags]    gcloud    gcp    instancegroup    access:read-only    data:metrics
    ${autoscale_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_autoscaling.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${autoscale_issues}=    RW.CLI.Run Cli
    ...    cmd=cat group_autoscaling_issues.json | jq '[.[] | select(.severity <= 3)] | length'
    ...    env=${env}
    ${autoscale_score}=    Evaluate    1 if """${autoscale_issues.stdout}""".strip() == "0" else 0
    Set Global Variable    ${autoscale_score}
    RW.Core.Push Metric    ${autoscale_score}    sub_name=autoscaling

Score Instance Group Patch Compliance for `${INSTANCE_GROUP_NAME}`
    [Documentation]    Scores 1 if all group members have current OS patches within PATCH_WARNING_DAYS.
    [Tags]    gcloud    gcp    instancegroup    osconfig    access:read-only    data:logs-config
    ${patch_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_group_patch_status.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${patch_issues}=    RW.CLI.Run Cli
    ...    cmd=cat group_patch_issues.json | jq '[.[] | select(.severity <= 3)] | length'
    ...    env=${env}
    ${patch_score}=    Evaluate    1 if """${patch_issues.stdout}""".strip() == "0" else 0
    Set Global Variable    ${patch_score}
    RW.Core.Push Metric    ${patch_score}    sub_name=patch_compliance

Score Instance Group Utilization for `${INSTANCE_GROUP_NAME}`
    [Documentation]    Scores 1 if average CPU utilization across group members is within the configured low/high bounds.
    [Tags]    gcloud    gcp    instancegroup    monitoring    access:read-only    data:metrics
    ${utilization_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_group_utilization.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${utilization_issues}=    RW.CLI.Run Cli
    ...    cmd=cat group_utilization_issues.json | jq '[.[] | select(.severity <= 3)] | length'
    ...    env=${env}
    ${utilization_score}=    Evaluate    1 if """${utilization_issues.stdout}""".strip() == "0" else 0
    Set Global Variable    ${utilization_score}
    RW.Core.Push Metric    ${utilization_score}    sub_name=utilization

Generate Instance Group Health Score for `${INSTANCE_GROUP_NAME}`
    [Documentation]    Averages the member health, autoscaling, patch compliance, and utilization sub-scores into the final 0-1 health score for the group.
    [Tags]    gcloud    gcp    instancegroup    access:read-only    data:logs-config
    ${health_score}=    Evaluate    (${member_score} + ${autoscale_score} + ${patch_score} + ${utilization_score}) / 4
    ${health_score}=    Convert to Number    ${health_score}    2
    RW.Core.Add to Report    Instance Group Health Score: ${health_score}
    RW.Core.Push Metric    ${health_score}

*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account json used to authenticate with GCP APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID", ... super secret stuff ...}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP Project ID hosting the instance groups.
    ...    pattern=\w*
    ...    example=myproject-ID
    ${INSTANCE_GROUP_NAME}=    RW.Core.Import User Variable    INSTANCE_GROUP_NAME
    ...    type=string
    ...    description=Name of the instance group to check. Set to a specific group for group-scoped scoring.
    ...    pattern=\w*
    ...    default=All
    ${PATCH_WARNING_DAYS}=    RW.Core.Import User Variable    PATCH_WARNING_DAYS
    ...    type=string
    ...    description=Days a missing/pending OS patch in the group may go unremediated before alerting.
    ...    pattern=^\d+$
    ...    default=30
    ${UTILIZATION_LOW_THRESHOLD}=    RW.Core.Import User Variable    UTILIZATION_LOW_THRESHOLD
    ...    type=string
    ...    description=Average CPU utilization percentage below which a group is considered under-utilized.
    ...    pattern=^\d+$
    ...    default=5
    ${UTILIZATION_HIGH_THRESHOLD}=    RW.Core.Import User Variable    UTILIZATION_HIGH_THRESHOLD
    ...    type=string
    ...    description=Average CPU utilization percentage above which a group is considered over-utilized.
    ...    pattern=^\d+$
    ...    default=90
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${INSTANCE_GROUP_NAME}    ${INSTANCE_GROUP_NAME}
    Set Suite Variable    ${PATCH_WARNING_DAYS}    ${PATCH_WARNING_DAYS}
    Set Suite Variable    ${UTILIZATION_LOW_THRESHOLD}    ${UTILIZATION_LOW_THRESHOLD}
    Set Suite Variable    ${UTILIZATION_HIGH_THRESHOLD}    ${UTILIZATION_HIGH_THRESHOLD}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}", "GCP_PROJECT_ID":"${GCP_PROJECT_ID}", "INSTANCE_GROUP_NAME":"${INSTANCE_GROUP_NAME}", "PATCH_WARNING_DAYS":"${PATCH_WARNING_DAYS}", "UTILIZATION_LOW_THRESHOLD":"${UTILIZATION_LOW_THRESHOLD}", "UTILIZATION_HIGH_THRESHOLD":"${UTILIZATION_HIGH_THRESHOLD}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
