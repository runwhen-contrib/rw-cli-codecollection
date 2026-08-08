*** Settings ***
Documentation       Scores GCP Apigee environment and edge health as a 0-1 value averaged across five dimensions: org/env state, instance attachment coverage, env group attachments, keystore certificate expiry, and target server configuration.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Apigee Environment and Edge Health
Metadata            Supports    GCP,Apigee,ApiGateway,Edge
Force Tags          GCP    Apigee    ApiGateway    Edge

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization

*** Tasks ***
Discover Apigee Topology for `${APIGEE_ORG}`
    [Documentation]    Builds the org topology dump used by the health-scoring dimensions.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=discover_topology.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180

Score Apigee Organization and Environment State for `${APIGEE_ORG}`
    [Documentation]    Scores 1.0 if the org and all environments are ACTIVE, 0.0 otherwise.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    data:state    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_org_env_state.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq length org_env_state_issues.json 2>/dev/null || echo 0
    ...    env=${env}
    ${state_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${state_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=unhealthy_env_count
    RW.Core.Push Metric    ${state_score}    sub_name=org_env_state

Score Apigee Instance Attachment Coverage for `${APIGEE_ORG}`
    [Documentation]    Scores 1.0 if every environment has at least one instance attachment, 0.0 otherwise.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    data:state    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_instance_attachments.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq length instance_attachment_issues.json 2>/dev/null || echo 0
    ...    env=${env}
    ${attach_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${attach_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=unattached_env_count
    RW.Core.Push Metric    ${attach_score}    sub_name=instance_attachment

Score Apigee Environment Group Attachments for `${APIGEE_ORG}`
    [Documentation]    Scores 1.0 if every environment group has an attachment and routed hostnames, 0.0 otherwise.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    data:state    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_envgroup_attachments.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq length envgroup_attachment_issues.json 2>/dev/null || echo 0
    ...    env=${env}
    ${envgroup_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${envgroup_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=unrouted_envgroup_count
    RW.Core.Push Metric    ${envgroup_score}    sub_name=envgroup_attachment

Score Apigee Keystore Certificate Health for `${APIGEE_ORG}`
    [Documentation]    Scores 1.0 if no keystore/truststore alias certificate expires within CERT_EXPIRY_WARNING_DAYS, 0.0 otherwise.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_keystore_cert_expiry.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq length keystore_cert_issues.json 2>/dev/null || echo 0
    ...    env=${env}
    ${cert_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${cert_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=expiring_cert_count
    RW.Core.Push Metric    ${cert_score}    sub_name=keystore_cert

Score Apigee Target Server Health for `${APIGEE_ORG}`
    [Documentation]    Scores 1.0 if all target servers are enabled and reachable, 0.0 otherwise.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_target_servers.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq length target_server_issues.json 2>/dev/null || echo 0
    ...    env=${env}
    ${target_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${target_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=bad_target_count
    RW.Core.Push Metric    ${target_score}    sub_name=target_server

Generate Aggregate Apigee Health Score for `${APIGEE_ORG}`
    [Documentation]    Averages the five dimension sub-scores into the final 0-1 health score.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    data:metrics    access:read-only
    ${health_score}=    Evaluate    (${state_score} + ${attach_score} + ${envgroup_score} + ${cert_score} + ${target_score}) / 5
    ${health_score}=    Convert to Number    ${health_score}    2
    RW.Core.Add to Report    Apigee Health Score: ${health_score} -- state: ${state_score}, attachments: ${attach_score}, envgroups: ${envgroup_score}, certs: ${cert_score}, targets: ${target_score}
    RW.Core.Push Metric    ${health_score}

*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account JSON used to authenticate with gcloud and the Apigee Management API.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID", ... super secret stuff ...}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP project ID that owns the Apigee organization.
    ...    pattern=\w*
    ...    example=myproject-ID
    ${APIGEE_ORG}=    RW.Core.Import User Variable    APIGEE_ORG
    ...    type=string
    ...    description=The Apigee organization name (organizations/{org}). If empty, discovered within GCP_PROJECT_ID.
    ...    pattern=\w*
    ...    default=
    ${ENVIRONMENTS}=    RW.Core.Import User Variable    ENVIRONMENTS
    ...    type=string
    ...    description=Comma-separated environment names to scope environment/target/keystore checks, or 'All'.
    ...    pattern=\w*
    ...    default=All
    ${CERT_EXPIRY_WARNING_DAYS}=    RW.Core.Import User Variable    CERT_EXPIRY_WARNING_DAYS
    ...    type=string
    ...    description=Days before a keystore alias certificate expires to raise a warning.
    ...    pattern=^\d+$
    ...    default=30
    ${TARGET_REACHABILITY_TIMEOUT}=    RW.Core.Import User Variable    TARGET_REACHABILITY_TIMEOUT
    ...    type=string
    ...    description=Timeout in seconds for the target server host/port reachability probe.
    ...    pattern=^\d+$
    ...    default=5
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${APIGEE_ORG}    ${APIGEE_ORG}
    Set Suite Variable    ${ENVIRONMENTS}    ${ENVIRONMENTS}
    Set Suite Variable    ${CERT_EXPIRY_WARNING_DAYS}    ${CERT_EXPIRY_WARNING_DAYS}
    Set Suite Variable    ${TARGET_REACHABILITY_TIMEOUT}    ${TARGET_REACHABILITY_TIMEOUT}
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","APIGEE_ORG":"${APIGEE_ORG}","ENVIRONMENTS":"${ENVIRONMENTS}","CERT_EXPIRY_WARNING_DAYS":"${CERT_EXPIRY_WARNING_DAYS}","TARGET_REACHABILITY_TIMEOUT":"${TARGET_REACHABILITY_TIMEOUT}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
