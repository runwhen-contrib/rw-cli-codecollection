*** Settings ***
Documentation       Azure Data Factories health checks including resource health status, frequent pipeline errors, failed pipeline runs, and large data operations monitoring.
Metadata            Author    saurabh3460
Metadata            Display Name    Azure Data factories Health
Metadata            Supports    Azure    Data factories
Force Tags          Azure    Data Factory    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Count Resource Health Issues Affecting Data Factories in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Fetch health status for all Data Factories in the resource group
    [Tags]    datafactory    resourcehealth   access:read-only
    ${json_file}=    Set Variable    "datafactory_health.json"
    ${resource_health}=    RW.CLI.Run Bash File
    ...    bash_file=resource_health.sh
    ...    env=${env}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${json_file}
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    ${availability_score}=    Evaluate    1 if len([issue for issue in ${issue_list} if issue["properties"]["title"] != "Available"]) > 0 else 0
    Set Global Variable    ${availability_score}
    RW.CLI.Run Cli
    ...    cmd=rm -f ${json_file}

Count Frequent Pipeline Errors in Data Factories in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Count frequently occurring errors in Data Factory pipelines
    [Tags]    datafactory    pipeline-errors    access:read-only
    ${json_file}=    Set Variable    "error_trend.json"
    ${error_check}=    RW.CLI.Run Bash File
    ...    bash_file=error_trend.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    TRY
        ${error_data}=    RW.CLI.Run Cli
        ...    cmd=cat ${json_file}
        ...    env=${env}
        ${error_trends}=    Evaluate    json.loads(r'''${error_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${error_trends}=    Create Dictionary    error_trends=[]
    END

    ${pipeline_error_score}=    Evaluate    1 if len(${error_trends['error_trends']}) > 0 else 0
    Set Global Variable    ${pipeline_error_score}

    RW.CLI.Run Cli
    ...    cmd=rm -f ${json_file}

Count Failed Pipelines in Data Factories in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Count failed pipeline runs in Data Factory pipelines
    [Tags]    datafactory    pipeline-failures    access:read-only
    ${json_file}=    Set Variable    "failed_pipelines.json"
    ${failed_check}=    RW.CLI.Run Bash File
    ...    bash_file=failed_pipeline.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    ${failed_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${json_file}

    TRY
        ${failed_json}=    Evaluate    json.loads(r'''${failed_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${failed_json}=    Create Dictionary    failed_json=[]
    END

    ${failed_pipeline_score}=    Evaluate    1 if len(${failed_json["failed_pipelines"]}) > 0 else 0
    Set Global Variable    ${failed_pipeline_score}

    RW.CLI.Run Cli
    ...    cmd=rm -f ${json_file}

Count Large Data Operations in Data Factories in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Count large data operations in Data Factory pipelines
    [Tags]    datafactory    data-volume    access:read-only
    ${json_file}=    Set Variable    "data_volume_audit.json"
    ${data_volume_check}=    RW.CLI.Run Bash File
    ...    bash_file=data_volume_audit.sh
    ...    env=${env}
    ...    include_in_history=false
    ${data_volume_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${json_file}

    TRY
        ${metrics_data}=    Evaluate    json.loads(r'''${data_volume_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${metrics_data}=    Create Dictionary    metrics_data=[]
    END

    ${data_volume_score}=    Evaluate    1 if len(${metrics_data.get("data_volume_alerts", [])}) > 0 else 0
    Set Global Variable    ${data_volume_score}

    RW.CLI.Run Cli
    ...    cmd=rm -f ${json_file}

Count Long Running Pipeline Runs in Data Factories in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Count long running pipeline runs in Data Factory pipelines
    [Tags]    datafactory    pipeline-long-running    access:read-only
    ${json_file}=    Set Variable    "long_pipeline_runs.json"
    ${long_run_check}=    RW.CLI.Run Bash File
    ...    bash_file=long_pipeline_runs.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    ${long_run_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${json_file}

    TRY
        ${long_runs}=    Evaluate    json.loads(r'''${long_run_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${long_runs}=    Create Dictionary    long_runs=[]
    END

    ${long_pipeline_score}=    Evaluate    1 if len(${long_runs.get("long_running_pipelines", [])}) > 0 else 0
    Set Global Variable    ${long_pipeline_score}

    RW.CLI.Run Cli
    ...    cmd=rm -f ${json_file}

Generate Health Score
    ${health_score}=      Evaluate  (${availability_score} + ${pipeline_error_score} + ${failed_pipeline_score} + ${data_volume_score} + ${long_pipeline_score}) / 5
    ${health_score}=      Convert to Number    ${health_score}  2
    RW.Core.Push Metric    ${health_score}

*** Keywords ***
Suite Initialization
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    ${AZURE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure Subscription ID for the resource.  
    ...    pattern=\w*
    ...    default=""
    ${AZURE_SUBSCRIPTION_NAME}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_NAME
    ...    type=string
    ...    description=The Azure Subscription Name.  
    ...    pattern=\w*
    ...    default=""
    ${AZURE_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZURE_RESOURCE_GROUP
    ...    type=string
    ...    description=Azure resource group.
    ...    pattern=\w*
    ${LOOKBACK_PERIOD}=    RW.Core.Import User Variable    LOOKBACK_PERIOD
    ...    type=string
    ...    description=The lookback period for querying failed pipelines (e.g., 1d, 7d, 30d).
    ...    pattern=\w*
    ...    default=7d
    ...    example=1d
    ${THRESHOLD_MB}=    RW.Core.Import User Variable    THRESHOLD_MB
    ...    type=string
    ...    description=The threshold for data volume in MB.
    ...    pattern=\w*
    ...    default=1000
    ...    example=5000
    ${FAILURE_THRESHOLD}=    RW.Core.Import User Variable    FAILURE_THRESHOLD
    ...    type=string
    ...    description=The threshold for failure count.
    ...    pattern=\w*
    ...    default=1
    ...    example=5
    ${RUN_TIME_THRESHOLD}=    RW.Core.Import User Variable    RUN_TIME_THRESHOLD
    ...    type=string
    ...    description=The threshold for run time of a pipeline in seconds.
    ...    pattern=\w*
    ...    default=600
    ...    example=600
    Set Suite Variable    ${THRESHOLD_MB}    ${THRESHOLD_MB}
    Set Suite Variable    ${LOOKBACK_PERIOD}    ${LOOKBACK_PERIOD}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_NAME}    ${AZURE_SUBSCRIPTION_NAME}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}", "AZURE_SUBSCRIPTION_NAME":"${AZURE_SUBSCRIPTION_NAME}", "LOOKBACK_PERIOD":"${LOOKBACK_PERIOD}", "THRESHOLD_MB":"${THRESHOLD_MB}", "FAILURE_THRESHOLD":"${FAILURE_THRESHOLD}", "RUN_TIME_THRESHOLD":"${RUN_TIME_THRESHOLD}"}