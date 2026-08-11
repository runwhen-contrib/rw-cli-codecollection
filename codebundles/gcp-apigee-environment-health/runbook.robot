*** Settings ***
Documentation       Identify health problems on the northbound and southbound edges of a GCP Apigee X organization (org/env state, instance & env group attachments and hostname routing, keystore certificate expiry, target server reachability, VPC peering / Private Service Connect, and instance capacity / failover)
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Apigee Environment and Edge Health
Metadata            Supports    GCP,Apigee,ApiGateway,Edge
Force Tags          GCP    Apigee    ApiGateway    Edge

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization

*** Tasks ***
Check Apigee Organization and Environment State in `${APIGEE_ORG}`
    [Documentation]    Flags the organization if it is not ACTIVE and flags every environment that is not in a healthy ACTIVE state or is stuck in CREATING/UPDATING/FAILED, since a non-serving environment is a total outage for its attached hostnames.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:state
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_org_env_state.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_org_env_state.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat org_env_state_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for org/env state, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Apigee Organization/Environment State:\n${result.stdout}

Check Apigee Environment to Instance Attachment Coverage in `${APIGEE_ORG}`
    [Documentation]    For each environment, verifies it is attached to at least one runtime instance and flags any environment with zero instance attachments, which means nothing routes or serves it even though the environment itself is configured correctly.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:state
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_instance_attachments.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_instance_attachments.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat instance_attachment_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for instance attachments, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Apigee Instance Attachment Coverage:\n${result.stdout}

Check Apigee Environment Group Attachments and Hostname Routing in `${APIGEE_ORG}`
    [Documentation]    For each environment group, verifies it has at least one attachment and that its hostnames are routed, flagging groups with no attached environment and hostnames that are not routed which produce edge-level 404s for callers.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:state
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_envgroup_attachments.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_envgroup_attachments.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat envgroup_attachment_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for env group attachments, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Apigee Environment Group Attachments:\n${result.stdout}

Check Apigee Keystore Alias Certificate Expiry in `${APIGEE_ORG}`
    [Documentation]    For each attached environment's keystores and truststores, inspects every alias certificate (northbound hostname TLS and southbound target TLS) and flags any that are expired or will expire within CERT_EXPIRY_WARNING_DAYS.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_keystore_cert_expiry.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_keystore_cert_expiry.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat keystore_cert_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for keystore cert expiry, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Apigee Keystore Certificate Expiry:\n${result.stdout}

Check Apigee Target Server Configuration and Reachability in `${APIGEE_ORG}`
    [Documentation]    For each target server per environment, verifies it is enabled and that its referenced host resolves and port is reachable, flagging disabled target servers and dangling targets whose host no longer resolves, which break every call routed to them.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_target_servers.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_target_servers.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat target_server_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for target servers, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Apigee Target Server Analysis:\n${result.stdout}

Check Apigee Southbound VPC Peering and Private Service Connect in `${GCP_PROJECT_ID}`
    [Documentation]    Inspects the Apigee org network configuration, VPC peering connections and Private Service Connect endpoints/attachments, flagging failed PSC endpoints and exhausted service peering ranges that break every southbound call while all Apigee resources still report healthy.
    [Tags]    gcloud    apigee    gcp    ${GCP_PROJECT_ID}    access:read-only    data:state
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_southbound_connectivity.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_southbound_connectivity.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat southbound_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for southbound connectivity, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Apigee Southbound Connectivity:\n${result.stdout}

Check Apigee Instance Capacity and Regional Failover in `${APIGEE_ORG}`
    [Documentation]    Flags runtime instances whose state is not ACTIVE or that are in reduced capacity, and reports whether any environment is served by only a single region/instance (no failover) so operators understand their resilience posture.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:state
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_instance_capacity.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_instance_capacity.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat capacity_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for instance capacity, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Apigee Instance Capacity & Failover:\n${result.stdout}

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
    ...    description=The Apigee organization name, either "my-org" or "organizations/my-org". If empty, it is discovered within GCP_PROJECT_ID.
    ...    pattern=\w*
    ...    default=
    ${ENVIRONMENTS}=    RW.Core.Import User Variable    ENVIRONMENTS
    ...    type=string
    ...    description=Comma-separated environment names to scope environment/target/keystore checks, or 'All' for every environment in the org.
    ...    pattern=\w*
    ...    default=All
    ${CERT_EXPIRY_WARNING_DAYS}=    RW.Core.Import User Variable    CERT_EXPIRY_WARNING_DAYS
    ...    type=string
    ...    description=Days before a keystore alias certificate expires to raise a warning (severity 2).
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
    # NOT `|| true`: a failed activation falls through to every later gcloud and
    # curl call, which then run as whatever ambient identity happens to exist --
    # or as none, reporting an empty Apigee org as a healthy one.
    ${auth}=    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}"
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    IF    ${auth.returncode} != 0
        RW.Core.Add Issue
        ...    severity=1
        ...    expected=The supplied gcp_credentials service account key should activate successfully.
        ...    actual=gcloud auth activate-service-account failed, so no Apigee API call in this run can be trusted.
        ...    title=Cannot authenticate to GCP with the supplied credentials
        ...    reproduce_hint=gcloud auth activate-service-account --key-file=<gcp_credentials>
        ...    details=${auth.stderr}
        ...    next_steps=Verify the gcp_credentials secret contains a valid, non-expired service account key for project ${GCP_PROJECT_ID}.
        Fail    Could not authenticate to GCP; not attempting any check.
    END

    # Discovery runs here, not as a task. It builds the topology every check
    # reads and can raise no finding about Apigee itself -- only about its own
    # ability to run. As a task it also produced a dishonest task list: when
    # discovery failed, all seven checks still ran, found nothing and rendered
    # as passed, which is indistinguishable from a healthy org. Failing setup
    # means they are not attempted instead.
    ${discovery}=    RW.CLI.Run Bash File
    ...    bash_file=discover_topology.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./discover_topology.sh
    RW.Core.Add Pre To Report    Apigee Topology Discovery:\n${discovery.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat discovery_issues.json 2>/dev/null || echo '[]'
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        # Unparseable output means discovery did not complete cleanly. Defaulting
        # to an empty list here would drop the failure entirely, so treat it as
        # one.
        Log    discovery_issues.json could not be parsed; treating discovery as failed.    WARN
        ${issue_list}=    Create List    ${{ {'severity': 2, 'title': 'Apigee topology discovery produced unreadable output', 'expected': 'discovery_issues.json should be valid JSON.', 'actual': 'discovery_issues.json was missing or unparseable.', 'details': r'''${issues.stdout}''', 'next_steps': 'Re-run discover_topology.sh directly and inspect its output.'} }}
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${discovery.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
        Fail    Apigee topology discovery failed; not attempting any check against an unread topology.
    END

    # A project with no Apigee organization is not a failure: discovery reports
    # that only on a positive determination of absence. The suite continues and
    # the checks correctly find nothing, rather than the whole run erroring.
    ${applicable}=    RW.CLI.Run Cli
    ...    cmd=jq -r '.org.applicable // true' apigee_topology.json 2>/dev/null || echo true
    ...    env=${env}
    IF    "${applicable.stdout}".strip() == "false"
        RW.Core.Add Pre To Report    No Apigee organization in project `${GCP_PROJECT_ID}` -- nothing for this runbook to check.
    END
