*** Settings ***
Documentation       Monitors the security posture and access configuration of an Apigee organization including API product quota/rate limits, developer app access scope, Apigee security score and incidents, and target server TLS configuration.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Apigee Security and Configuration Health
Metadata            Supports    GCP,Apigee,Security
Force Tags          GCP    Apigee    Security    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
# There is no keystore alias expiry task here. The sibling
# gcp-apigee-environment-health bundle already checks exactly that, in
# check_keystore_cert_expiry.sh, and it gates on the SAME resource type
# (gcp_apigee_organizations) -- so both bundles produce an SLX for the same
# organization and the same expiring certificate would raise the same finding
# twice, against two different SLXs, with the same remedy. That is alert noise,
# not defence in depth. See the README for the full reasoning.
Check Apigee API Product Quota and Rate Limits in `${APIGEE_ORG}`
    [Documentation]    Reviews API products' quota, rate limit, and approval settings, flagging products with no quota, extreme quota, or auto-approval.
    [Tags]    gcp    apigee    quota    security    data:config    access:read-only
    ${quota_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_quota_limits.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=240
    ...    cmd_override=./check_quota_limits.sh
    ${quota_issues}=    RW.CLI.Run Cli
    ...    cmd=cat quota_limits_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${quota_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for quota limits, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${quota_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Apigee API Product Quota Analysis:\n${quota_result.stdout}

Check Apigee Developer App Access Scope in `${APIGEE_ORG}`
    [Documentation]    Reviews developer apps and consumer keys for over-broad scopes and inactive keys that pose an access-control risk.
    [Tags]    gcp    apigee    access    security    data:config    access:read-only
    ${app_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_app_access.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=240
    ...    cmd_override=./check_app_access.sh
    ${app_issues}=    RW.CLI.Run Cli
    ...    cmd=cat app_access_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${app_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for app access, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${app_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Apigee Developer App Access Analysis:\n${app_result.stdout}

Check Apigee Security Score and Incidents in `${APIGEE_ORG}`
    [Documentation]    Queries Apigee security metrics to flag organizations with a low security score or a high number of detected incidents.
    [Tags]    gcp    apigee    security    monitoring    data:metrics    access:read-only
    ${score_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_security_score.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_security_score.sh
    ${score_issues}=    RW.CLI.Run Cli
    ...    cmd=cat security_score_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${score_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for security score, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${score_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Apigee Security Score Analysis:\n${score_result.stdout}

Check Apigee Target Server and Virtual Host Configuration in `${APIGEE_ORG}`
    [Documentation]    Reviews target servers for missing or incorrect TLS configuration, flagging plaintext or misconfigured backends.
    [Tags]    gcp    apigee    tls    targetserver    security    data:config    access:read-only
    ${target_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_target_vhost_config.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_target_vhost_config.sh
    ${target_issues}=    RW.CLI.Run Cli
    ...    cmd=cat target_vhost_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${target_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for target/vhost config, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${target_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Apigee Target Server / Virtual Host Analysis:\n${target_result.stdout}


*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account JSON key used to authenticate with Apigee Admin and Cloud Monitoring APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID"}
    ${APIGEE_ORG}=    RW.Core.Import User Variable    APIGEE_ORG
    ...    type=string
    ...    description=Apigee organization name (security/config scope).
    ...    pattern=\w*
    ...    example=my-apigee-org
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=GCP Project ID hosting the Apigee runtime (used for security metric queries).
    ...    pattern=\w*
    ...    example=my-gcp-project
    ${QUOTA_ABUSE_THRESHOLD}=    RW.Core.Import User Variable    QUOTA_ABUSE_THRESHOLD
    ...    type=string
    ...    description=Quota value (requests/time) at or above which an API product is flagged as excessive.
    ...    pattern=\w*
    ...    default=1000000
    ${SECURITY_SCORE_THRESHOLD}=    RW.Core.Import User Variable    SECURITY_SCORE_THRESHOLD
    ...    type=string
    ...    description=Minimum acceptable Apigee security score (0-100) before the org is flagged.
    ...    pattern=\w*
    ...    default=80
    ${SECURITY_WINDOW_HOURS}=    RW.Core.Import User Variable    SECURITY_WINDOW_HOURS
    ...    type=string
    ...    description=Lookback window in hours for the Apigee security metric queries.
    ...    pattern=^\d+$
    ...    default=6
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${APIGEE_ORG}    ${APIGEE_ORG}
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${QUOTA_ABUSE_THRESHOLD}    ${QUOTA_ABUSE_THRESHOLD}
    Set Suite Variable    ${SECURITY_SCORE_THRESHOLD}    ${SECURITY_SCORE_THRESHOLD}
    Set Suite Variable    ${SECURITY_WINDOW_HOURS}    ${SECURITY_WINDOW_HOURS}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"PATH":"$PATH:${OS_PATH}","APIGEE_ORG":"${APIGEE_ORG}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","QUOTA_ABUSE_THRESHOLD":"${QUOTA_ABUSE_THRESHOLD}","SECURITY_SCORE_THRESHOLD":"${SECURITY_SCORE_THRESHOLD}","SECURITY_WINDOW_HOURS":"${SECURITY_WINDOW_HOURS}"}
    # Activation is best-effort. The runner may already carry a usable identity
    # (workload identity), in which case a failed activation is cosmetic -- which
    # is why the other GCP bundles in this collection all suffix this call with
    # `|| true`. Gating the suite on the activation's exit code turned that
    # cosmetic failure into a total outage: every task reported NOT RUN.
    ${auth}=    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}

    # Determine the key file's SHAPE rather than inferring it from the activation
    # error. "Missing required argument [ACCOUNT]: An account is required when
    # using .p12 keys" does not mean the key is a p12 -- it means gcloud's
    # json.load() failed and it fell back to assuming one. That single error
    # covers an absent file, an empty file, and a file whose contents are not
    # JSON at all (a base64-encoded key stored without being decoded is the
    # usual cause), which are three different things to go fix.
    #
    # Emits a sentinel only. No byte of the key is echoed, logged or put in an
    # issue -- the shape is the diagnostic, the contents are not.
    ${keyshape}=    RW.CLI.Run CLI
    ...    cmd=f="./${gcp_credentials.key}"; if [ ! -f "$f" ]; then echo KEY_MISSING; elif [ ! -s "$f" ]; then echo KEY_EMPTY; elif [ "$(head -c 512 "$f" | tr -d '[:space:]' | cut -c1)" = "{" ]; then echo KEY_JSON; else echo KEY_NOT_JSON; fi
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    Log    gcp_credentials key file shape: ${keyshape.stdout}

    # This check is NOT tolerant, and it is the one that matters. Assert the
    # capability every downstream gcloud and curl call actually depends on -- can
    # a token be minted -- rather than the mechanism that usually supplies it.
    # With no token, those calls run as no identity at all: every check finds
    # nothing, reports no issues, and the run renders as a healthy org while it
    # was in fact blind.
    ${token}=    RW.CLI.Run CLI
    ...    cmd=gcloud auth print-access-token >/dev/null 2>&1 && echo TOKEN_OK || echo TOKEN_ABSENT
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    IF    "TOKEN_ABSENT" in """${token.stdout}"""
        RW.Core.Add Issue
        ...    severity=1
        ...    expected=An access token should be obtainable, whether from the gcp_credentials key or from an ambient runner identity.
        ...    actual=No access token could be minted, so no Apigee API call in this run can be trusted.
        ...    title=Cannot authenticate to GCP with the supplied credentials
        ...    reproduce_hint=gcloud auth activate-service-account --key-file=<gcp_credentials> && gcloud auth print-access-token
        ...    details=gcp_credentials key file shape: ${keyshape.stdout}\n(KEY_JSON = well-formed, so suspect the key's contents or IAM; KEY_NOT_JSON = not JSON at all, commonly a base64-encoded key stored without decoding; KEY_EMPTY / KEY_MISSING = the secret did not reach the runner.)\n\nactivate-service-account stderr:\n${auth.stderr}\n\nprint-access-token stderr:\n${token.stderr}
        ...    next_steps=Verify the gcp_credentials secret contains a valid, non-expired service account JSON key for project ${GCP_PROJECT_ID}, stored as raw JSON rather than base64.
        Fail    Could not obtain a GCP access token; not attempting any check.
    END
