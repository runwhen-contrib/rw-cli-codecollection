*** Settings ***
Documentation       Runs diagnostic checks to check the health of APIM instances
Metadata            Author    stewartshea
Metadata            Display Name    Azure APIM Health
Metadata            Supports    Azure    APIM    Service    Triage    Health

Library             BuiltIn
Library             String
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check for Resource Health Issues Affecting APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch Resource Health status and evaluate any reported issues for the APIM instance.
    [Tags]    apim    resourcehealth    access:read-only

    ${resource_health}=    RW.CLI.Run Bash File
    ...    bash_file=apim_resource_health.sh
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat apim_resource_health.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    ${resource_health_output_json}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{resource_health_output_json}) > 0 
        ${apim_resource_score}=    Evaluate    1 if "${resource_health_output_json["properties"]["title"]}" == "Available" else 0
    ELSE
        ${apim_resource_score}=    Set Variable    0
    END
    Set Global Variable    ${apim_resource_score}
    RW.Core.Push Metric    ${apim_resource_score}    sub_name=resource_health

Fetch Key Metrics for APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Gather APIM metrics from Azure Monitor. Raises issues if thresholds are violated.
    [Tags]    apim    metrics    analytics    access:read-only

    ${apim_metrics}=    RW.CLI.Run Bash File
    ...    bash_file=apim_metrics.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat apim_metrics.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ${issues_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    ${apim_metric_score}=    Evaluate    1 if len(@{issues_list["issues"]}) == 0 else 0
    Set Global Variable    ${apim_metric_score}
    RW.Core.Push Metric    ${apim_metric_score}    sub_name=metrics

Check Logs for Errors with APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Run apim_diagnostic_logs.sh, parse results, raise issues if logs exceed thresholds.
    [Tags]    apim    logs    diagnostics    access:read-only

    ${diag_run}=    RW.CLI.Run Bash File
    ...    bash_file=apim_diagnostic_logs.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat apim_diagnostic_log_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    ${apim_log_score}=    Evaluate    1 if len(@{issue_list["issues"]}) == 0 else 0
    Set Global Variable    ${apim_log_score}
    RW.Core.Push Metric    ${apim_log_score}    sub_name=diagnostic_logs


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

    # Read the final JSON file (apim_policy_issues.json)
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat apim_policy_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    ${apim_config_score}=    Evaluate    1 if len(@{issue_list["issues"]}) == 0 else 0
    Set Global Variable    ${apim_config_score}
    RW.Core.Push Metric    ${apim_config_score}    sub_name=policy_config

Check APIM SSL Certificates for `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Verify certificate validity, expiration, thumbprint, and domain matches
    [Tags]    apim    ssl    certificate    access:read-only

    ${cert_check}=    RW.CLI.Run Bash File
    ...    bash_file=check_apim_ssl_certs.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat apim_ssl_certificate_issues.json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    ${apim_ssl_score}=    Evaluate    1 if len(@{issue_list["issues"]}) == 0 else 0
    Set Global Variable    ${apim_ssl_score}
    RW.Core.Push Metric    ${apim_ssl_score}    sub_name=ssl_certificates

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
    ${apim_dep_score}=    Evaluate    1 if len(@{issue_list}) == 0 else 0
    Set Global Variable    ${apim_dep_score}
    RW.Core.Push Metric    ${apim_dep_score}    sub_name=dependencies

Generate APIM Health Score
    ${apim_health_score}=      Evaluate  (${apim_dep_score} + ${apim_ssl_score} + ${apim_config_score} + ${apim_log_score} + ${apim_metric_score} + ${apim_resource_score} ) / 6
    ${health_score}=      Convert to Number    ${apim_health_score}  2
    RW.Core.Push Metric    ${health_score}

*** Keywords ***
Normalize Lookback Window
    [Arguments]    ${raw}
    ${raw}=    Strip String    ${raw}
    ${raw}=    Replace String Using Regexp    ${raw}    \s+    ${EMPTY}
    ${len}=    Get Length    ${raw}
    Should Be True    ${len} >= 2
    ${num}=    Get Substring    ${raw}    0    ${len-1}
    Should Match Regexp    ${num}    ^[0-9]+$
    ${num}=    Convert To Integer    ${num}
    RETURN    ${num}
Suite Initialization
    ${AZ_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZ_RESOURCE_GROUP
    ...    type=string
    ...    description=The resource group to perform actions against.
    ...    pattern=\w*
    ${APIM_NAME}=    RW.Core.Import User Variable    APIM_NAME
    ...    type=string
    ...    description=The APIM Instance Name
    ...    pattern=\w*
    ${LOOKBACK_WINDOW}=    RW.Core.Import Platform Variable    RW_LOOKBACK_WINDOW
    ${TIME_PERIOD_MINUTES}=    Normalize Lookback Window    ${LOOKBACK_WINDOW}
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
    # Set Azure subscription context
    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
    ...    include_in_history=false

