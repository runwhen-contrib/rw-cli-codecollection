*** Settings ***
Documentation       Runs diagnostic checks to check the health of APIM instances
Metadata            Author    stewartshea
Metadata            Display Name    Azure APIM Health
Metadata            Supports    Azure    APIM    Service    Triage    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Gather APIM Resource Information for APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Collect fundamental details about the Azure subscription, resource group,
    ...               and the APIM instance before proceeding with troubleshooting.
    [Tags]    apim    config    access:read-only
    ${apim_config}=    RW.CLI.Run Bash File
    ...    bash_file=gather_apim_resource_information.sh
    ...    env=${env}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${apim_config.stdout}
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat apim_config_issues.json
    ...    env=${env}
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0 
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue
            ...    severity=${item["severity"]}
            ...    expected=APIM config should not have recommendations
            ...    actual=APIM config ahs recommendations
            ...    title=${item["title"]}
            ...    reproduce_hint=${apim_config.cmd}
            ...    details=${item["details"]}
            ...    next_steps=${item["next_steps"]}
        END
    END

Check for Resource Health Issues Affecting APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch Resource Health status and evaluate any reported issues for the APIM instance.
    [Tags]    apim    resourcehealth    access:read-only

    ${resource_health}=    RW.CLI.Run Bash File
    ...    bash_file=apim_resource_health.sh
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true

    RW.Core.Add Pre To Report    ${resource_health.stdout}

    IF    "${resource_health.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Warnings/Errors running APIM Resource Health script
        ...    severity=3
        ...    next_steps=Review debug logs in the Robot report
        ...    expected=No stderr output
        ...    actual=stderr encountered
        ...    reproduce_hint=${resource_health.cmd}
        ...    details=${resource_health.stderr}
    END

    # 4) Read the JSON output from apim_resource_health.json
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat apim_resource_health.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json

    IF    len(${issue_list}) > 0
        # We assume the returned JSON is an object, not an array. Adjust accordingly if it's different.
        ${status_title}=    Set Variable    ${issue_list["properties"]["title"]}

        IF    "${status_title}" != "Available"
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=APIM should be marked "Available" in Resource Health
            ...    actual=Azure resources are unhealthy for APIM `${APIM_NAME}` in `${AZ_RESOURCE_GROUP}`
            ...    title=Azure reports a `${status_title}` issue for APIM `${APIM_NAME}` in `${AZ_RESOURCE_GROUP}`
            ...    reproduce_hint=${resource_health.cmd}
            ...    details=${issue_list}
            ...    next_steps=Consult Azure Resource Health documentation or escalate to service owner.
        END
    ELSE
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=APIM Resource Health should return a valid status
        ...    actual=No valid data returned or JSON was empty
        ...    title=APIM Resource Health is unavailable for `${APIM_NAME}` in `${AZ_RESOURCE_GROUP}`
        ...    reproduce_hint=${resource_health.cmd}
        ...    details=${issue_list}
        ...    next_steps=Enable Resource Health or check provider registration for Microsoft.ResourceHealth
    END

Fetch Key Metrics for APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Gather APIM metrics from Azure Monitor. Raises issues if thresholds are violated.
    [Tags]    apim    metrics    analytics    access:read-only

    ${apim_metrics}=    RW.CLI.Run Bash File
    ...    bash_file=apim_metrics.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    RW.Core.Add Pre To Report    ${apim_metrics.stdout}

    IF    "${apim_metrics.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Error retrieving APIM metrics
        ...    severity=3
        ...    next_steps=Check debug logs in report
        ...    expected=No stderr output
        ...    actual=Stderr encountered
        ...    reproduce_hint=${apim_metrics.cmd}
        ...    details=${apim_metrics.stderr}
    END

    ${metrics_output}=    RW.CLI.Run Cli
    ...    cmd=cat apim_metrics.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    ${parsed}=    Evaluate    json.loads(r'''${metrics_output.stdout}''')    json
    ${issues}=    Set Variable    ${parsed["issues"]}

    IF    len(@{issues}) > 0
        FOR    ${issue}    IN    @{issues}
            RW.Core.Add Issue
            ...    title=${issue["title"]}
            ...    severity=${issue["severity"]}
            ...    next_steps=${issue["next_steps"]}
            ...    expected=APIM performance should remain within healthy thresholds
            ...    actual=Potential problem flagged in metrics
            ...    reproduce_hint=${run_metrics.cmd}
            ...    details=${issue["details"]}
        END
    END

Check Logs for Errors with APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Run apim_diagnostic_logs.sh, parse results, raise issues if logs exceed thresholds.
    [Tags]    apim    logs    diagnostics    access:read-only

    ${diag_run}=    RW.CLI.Run Bash File
    ...    bash_file=apim_diagnostic_logs.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    RW.Core.Add Pre To Report    ${diag_run.stdout}

    IF    "${diag_run.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Error/Warning Running APIM Diagnostic Script
        ...    severity=3
        ...    next_steps=Review debug logs in report
        ...    expected=No stderr output
        ...    actual=stderr encountered
        ...    reproduce_hint=${diag_run.cmd}
        ...    details=${diag_run.stderr}
    END

    # Parse the JSON file for issues
    ${log_json}=    RW.CLI.Run Cli
    ...    cmd=cat apim_diagnostic_log_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    ${parsed}=    Evaluate    json.loads(r'''${log_json.stdout}''')    json
    ${apim_log_issues}=    Set Variable    ${parsed["issues"]}

    IF    len(@{apim_log_issues}) > 0
        FOR    ${item}    IN    @{apim_log_issues}
            RW.Core.Add Issue
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_steps"]}
            ...    expected=APIM logs show no repeated errors/warnings
            ...    actual=Some errors/warnings found above threshold
            ...    reproduce_hint=${diag_run.cmd}
            ...    details=${item["details"]}
        END
    END

Verify APIM Policy Configurations for `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Runs a shell script to enumerate all APIM policies and check for missing tags.
    [Tags]    apim    policy    config    access:read-only

    ${policy_check}=    RW.CLI.Run Bash File
    ...    bash_file=verify_apim_policies.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false

    # Include script stdout in the test report
    RW.Core.Add Pre To Report    ${policy_check.stdout}

    # If there's any stderr, raise an immediate issue
    IF    "${policy_check.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Errors while verifying APIM policies
        ...    severity=3
        ...    next_steps=Review the debug logs in the report
        ...    expected=No stderr output
        ...    actual=stderr encountered
        ...    reproduce_hint=${policy_check.cmd}
        ...    details=${policy_check.stderr}
    END

    # Read the final JSON file (apim_policy_issues.json)
    ${issues_json}=    RW.CLI.Run Cli
    ...    cmd=cat apim_policy_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    ${parsed}=    Evaluate    json.loads(r'''${issues_json.stdout}''')    json
    ${policy_issues}=    Set Variable    ${parsed["issues"]}

    IF    len(@{policy_issues}) > 0
        FOR    ${issue}    IN    @{policy_issues}
            RW.Core.Add Issue
            ...    title=${issue["title"]}
            ...    severity=${issue["severity"]}
            ...    next_steps=${issue["next_steps"]}
            ...    expected=All APIM policies are well configured
            ...    actual=Potential misconfiguration found
            ...    reproduce_hint=${policy_check.cmd}
            ...    details=${issue["details"]}
        END
    END

Check APIM SSL Certificates for `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Verify certificate validity, expiration, thumbprint, and domain matches
    [Tags]    apim    ssl    certificate    access:read-only

    ${cert_check}=    RW.CLI.Run Bash File
    ...    bash_file=check_apim_ssl_certs.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    RW.Core.Add Pre To Report    ${cert_check.stdout}

    IF    "${cert_check.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Errors while checking APIM SSL Certificates
        ...    severity=3
        ...    next_steps=Review the debug logs in the Robot report
        ...    expected=No stderr
        ...    actual=Errors encountered
        ...    reproduce_hint=${cert_check.cmd}
        ...    details=${cert_check.stderr}
    END

    ${cert_issues_cmd}=    RW.CLI.Run Cli
    ...    cmd=cat apim_ssl_certificate_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    ${parsed}=    Evaluate    json.loads(r'''${cert_issues_cmd.stdout}''')    json
    ${issues}=    Set Variable    ${parsed["issues"]}

    IF    len(@{issues}) > 0
        FOR    ${item}    IN    @{issues}
            RW.Core.Add Issue
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_steps"]}
            ...    expected=All custom domain certificates are valid
            ...    actual=Certificate mismatch or near/over expiry
            ...    reproduce_hint=${cert_check.cmd}
            ...    details=${item["details"]}
        END
    END

Inspect Dependencies and Related Resources for APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Runs inspect_apim_dependencies.sh to discover & validate Key Vault, backends, DNS, etc.
    [Tags]    apim    dependencies    external    keyvault

    ${deps_run}=    RW.CLI.Run Bash File
    ...    bash_file=inspect_apim_dependencies.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false

    RW.Core.Add Pre To Report    ${deps_run.stdout}

    IF    "${deps_run.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Errors inspecting APIM dependencies
        ...    severity=3
        ...    next_steps=Review debug logs in the Robot report
        ...    expected=No stderr output
        ...    actual=stderr encountered
        ...    reproduce_hint=${deps_run.cmd}
        ...    details=${deps_run.stderr}
    END

    ${deps_json_cmd}=    RW.CLI.Run Cli
    ...    cmd=cat apim_dependencies.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    ${parsed}=    Evaluate    json.loads(r'''${deps_json_cmd.stdout}''')    json
    ${issue_list}=    Set Variable    ${parsed["issues"]}
    ${dep_list}=      Set Variable    ${parsed["dependencies"]}

    # Optionally: log the discovered dependencies in the report
    RW.Core.Add Pre To Report    Found dependencies: ${dep_list}

    IF    len(@{issue_list}) > 0
        FOR    ${item}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_steps"]}
            ...    expected=Dependencies for APIM are all healthy / reachable
            ...    actual=Some dependencies are unhealthy or unreachable
            ...    reproduce_hint=${deps_run.cmd}
            ...    details=${item["details"]}
        END
    END

*** Keywords ***
Suite Initialization
    ${AZ_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZ_RESOURCE_GROUP
    ...    type=string
    ...    description=The resource group to perform actions against.
    ...    pattern=\w*
    ${APIM_NAME}=    RW.Core.Import User Variable    APIM_NAME
    ...    type=string
    ...    description=The APIM Instance Name
    ...    pattern=\w*
    ${TIME_PERIOD_MINUTES}=    RW.Core.Import User Variable    TIME_PERIOD_MINUTES
    ...    type=string
    ...    description=The time period, in minutes, to look back for activites/events. 
    ...    pattern=\w*
    ...    default=60
    ${AZURE_RESOURCE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_RESOURCE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure Subscription ID for the resource.  
    ...    pattern=\w*
    ...    default=""
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    Set Suite Variable    ${AZURE_RESOURCE_SUBSCRIPTION_ID}    ${AZURE_RESOURCE_SUBSCRIPTION_ID}
    Set Suite Variable    ${APIM_NAME}    ${APIM_NAME}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable    ${TIME_PERIOD_MINUTES}    ${TIME_PERIOD_MINUTES}
    Set Suite Variable
    ...    ${env}
    ...    {"APIM_NAME":"${APIM_NAME}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}", "TIME_PERIOD_MINUTES":"${TIME_PERIOD_MINUTES}", "AZURE_RESOURCE_SUBSCRIPTION_ID":"${AZURE_RESOURCE_SUBSCRIPTION_ID}"}
