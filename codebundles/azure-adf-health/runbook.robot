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
Library             Jenkins
Suite Setup         Suite Initialization


*** Tasks ***
Check for Resource Health Issues Affecting Data Factories in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Fetch health status for all Data Factories in the resource group
    [Tags]    datafactory    resourcehealth   access:read-only
    ${json_file}=    Set Variable    "datafactory_health.json"
    ${resource_health}=    RW.CLI.Run Bash File
    ...    bash_file=resource_health.sh
    ...    timeout_seconds=180
    ...    env=${env}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${json_file}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON from ${json_file}.    WARN
        ${issue_list}=    Create List
    END
    ${found}=    Set Variable    ${False}
    IF    len(${issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            IF    "${issue["properties"]["title"]}" != "Available"
                RW.Core.Add Issue
                ...    severity=3
                ...    expected=Azure Data Factory resources should be available in resource group `${AZURE_RESOURCE_GROUP}`
                ...    actual=Azure Data Factory resources are unhealthy in resource group `${AZURE_RESOURCE_GROUP}`
                ...    title=Azure reports an `${issue["properties"]["title"]}` Issue for Data Factory
                ...    reproduce_hint=${resource_health.cmd}
                ...    details=${issue}
                ...    next_steps=Please escalate to the Azure service owner or check back later.
                ${found}=    Set Variable    ${True}
            END
        END
        IF    not ${found}
            RW.Core.Add Pre To Report    All Data Factories are healthy in resource group `${AZURE_RESOURCE_GROUP}`.
        END
    ELSE
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Azure resources health should be enabled for Data Factories in resource group `${AZURE_RESOURCE_GROUP}`
        ...    actual=Azure resource health appears unavailable for Data Factories in resource group `${AZURE_RESOURCE_GROUP}`
        ...    title=Azure resource health is unavailable for Data Factories in resource group `${AZURE_RESOURCE_GROUP}`
        ...    reproduce_hint=${resource_health.cmd}
        ...    details=${issue_list}
        ...    next_steps=Please escalate to the Azure service owner to enable provider Microsoft.ResourceHealth.
    END

List Frequent Pipeline Errors in Data Factories in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    List frequently occurring errors in Data Factory pipelines
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
        ${error_trends}=    Evaluate    json.loads(r'''${error_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${error_trends}=    Create Dictionary    error_trends=[]
    END

    IF    len(${error_trends['error_trends']}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["Pipeline_Name", "Last_Seen", "Failure_Count", "RunId", "Resource_URL"], (.error_trends[] | [ .name, (.details | fromjson).LastSeen, (.details | fromjson).FailureCount, .run_id, .resource_url]) | @tsv' ${json_file} | column -t
        RW.Core.Add Pre To Report    Pipeline Error Trends Summary:\n==============================\n${formatted_results.stdout}

        FOR    ${error}    IN    @{error_trends['error_trends']}
            ${details_json}=    Evaluate    json.loads(r'''${error["details"]}''')    json
            ${messages}=    Evaluate    json.loads(r'''${details_json["Messages"]}''')
            ${failure_count}=    Evaluate    int(${details_json["FailureCount"]})
            IF    ${failure_count} > ${FAILURE_THRESHOLD}
                ${next_steps}=    Analyze Logs
                ...    logs=${messages[0]}
                ...    error_patterns_file=error_patterns.json
                ${suggestions}=    Set Variable    ${EMPTY}
                ${logs_details}=    Set Variable    ${EMPTY}
                FOR    ${step}    IN    @{next_steps}
                    ${suggestions}=    Set Variable    ${suggestions}${step['suggestion']}\n
                    ${logs_details}=    Set Variable    ${logs_details}Log: ${step['log']}\n
                END
                RW.Core.Add Issue
                ...    severity=${error.get("severity", 4)}
                ...    expected=${error.get("expected", "No expected value")}
                ...    actual=${error.get("actual", "No actual value")}
                ...    title=${error.get("title", "No title")}
                ...    reproduce_hint=${error.get("reproduce_hint", "No reproduce hint")}
                ...    details=${error.get("details", "No details")}
                ...    next_steps=${suggestions}
            ELSE
                RW.Core.Add Pre To Report    "No Frequent Pipeline Errors found in resource group `${AZURE_RESOURCE_GROUP}`"
            END
        END
    ELSE
        RW.Core.Add Pre To Report    "No Frequent Pipeline Errors found in resource group `${AZURE_RESOURCE_GROUP}`"
    END


List Failed Pipelines in Data Factories in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    List failed pipeline runs in Data Factory pipelines
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

    ${has_failures}=    Evaluate    len($failed_json["failed_pipelines"]) > 0

    IF    ${has_failures}
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '.failed_pipelines[] | "Pipeline_Name: \\(.name)", "RunId: \\(.run_id)", "Resource_URL: \\(.resource_url)", "Linked_Services :", (.linked_services[] | " - \\(.name)\t\\(.properties.type)\t\\(.url)"), "----------------"' ${json_file}
        RW.Core.Add Pre To Report    Failed Pipelines Summary:\n==============================\n${formatted_results.stdout}
       
        FOR    ${issue}    IN    @{failed_json["failed_pipelines"]}
            ${details_json}=    Evaluate    json.loads('''${issue["details"]}''')    json
            ${linked_services}=    Set Variable    ${issue.get("linked_services", [])}
            ${merged}=    Evaluate    dict(${details_json}, linked_services=${linked_services})
            ${next_steps}=    Analyze Logs
            ...    logs=${details_json["Message"]}
            ...    error_patterns_file=error_patterns.json
            ${suggestions}=    Set Variable    ${EMPTY}
            ${logs_details}=    Set Variable    ${EMPTY}
            FOR    ${step}    IN    @{next_steps}
                ${suggestions}=    Set Variable    ${suggestions}${step['suggestion']}\n
                ${logs_details}=    Set Variable    ${logs_details}Log: ${step['log']}\n
            END
            RW.Core.Add Issue
            ...    severity=${issue.get("severity", 4)}
            ...    title=${issue.get("title", "No title")}
            ...    details=${merged}
            ...    next_steps=${suggestions}
            ...    expected=${issue.get("expected", "No expected value")}
            ...    actual=${issue.get("actual", "No actual value")}
            ...    reproduce_hint=${issue.get("reproduce_hint", "No reproduce hint")}
        END
    ELSE
        RW.Core.Add Pre To Report    "No failed pipelines found in resource group `${AZURE_RESOURCE_GROUP}`"
    END


Find Large Data Operations in Data Factories in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    List large data operations in Data Factory pipelines
    [Tags]    datafactory    data-volume    access:read-only
    ${json_file}=    Set Variable    "data_volume_audit.json"
    ${data_volume_check}=    RW.CLI.Run Bash File
    ...    bash_file=data_volume_audit.sh
    ...    timeout_seconds=180
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

    ${has_heavy_operations}=    Evaluate    len($metrics_data.get("data_volume_alerts", [])) > 0

    IF    ${has_heavy_operations}
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["Pipeline_Name", "RunId", "Output_dataRead_d", "Output_dataWritten_d", "Resource_URL"], (.data_volume_alerts[] | [ .name, .run_id, (.details | fromjson).Output_dataRead_d, (.details | fromjson).Output_dataWritten_d, .resource_url]) | @tsv' ${json_file} | column -t
        RW.Core.Add Pre To Report    Heavy Data Operations Summary:\n==============================\n${formatted_results.stdout}

        FOR    ${issue}    IN    @{metrics_data["data_volume_alerts"]}
            RW.Core.Add Issue
            ...    severity=${issue.get("severity", 4)}
            ...    title=${issue.get("title", "No title")}
            ...    details=${issue.get("details", "No details")}
            ...    next_steps=${issue.get("next_step", "No next steps")}
            ...    expected=${issue.get("expected", "No expected value")}
            ...    actual=${issue.get("actual", "No aFailed Job Runs Log Parser SLI to run every 120-180 seconds to do a KQL query to find failed job run, fetch detailctual value")}
            ...    reproduce_hint=${issue.get("reproduce_hint", "No reproduce hint")}
        END
    ELSE
        RW.Core.Add Pre To Report    "No heavy data operations detected in resource group `${AZURE_RESOURCE_GROUP}`"
    END



Fetch Azure Data Factory Details in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    List comprehensive details about Azure Data Factories
    ${json_file}=    Set Variable    "adf_details.json"
    
    ${data_volume_check}=    RW.CLI.Run Bash File
    ...    bash_file=adf_details.sh
    ...    timeout_seconds=180
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

    ${adf_details}=    Evaluate    len(${metrics_data.get("data_factories", [])}) > 0

    IF    ${adf_details}
        ${diag_info}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["Data_Factory", "Location", "Resource_Group","Diag_Status", "Pipeline_Logging", "Activity_Logging", "Trigger_Logging", "Linked_Services", "ADF_URL"], (.data_factories[] | [ .name, .location, .resource_group, .diagnostics.status, .diagnostics.pipeline_logging_enabled, .diagnostics.activity_logging_enabled, .diagnostics.trigger_logging_enabled, ([.components.linked_services[].name]|join(", ")), .url]) | @tsv' ${json_file} | column -t -s $'\t'
        RW.Core.Add Pre To Report    \nDiagnostic Settings and Linked Services:\n=====================================\n${diag_info.stdout}

    ELSE
        RW.Core.Add Pre To Report    No Data Factories found in resource group '${AZURE_RESOURCE_GROUP}' or unable to retrieve data.
    END


List Long Running Pipeline Runs in Data Factories in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    List long running pipeline runs in Data Factory pipelines
    [Tags]    datafactory    long-running-pipelines    access:read-only
    ${json_file}=    Set Variable    "long_pipeline_runs.json"
    ${long_pipeline_runs_check}=    RW.CLI.Run Bash File
    ...    bash_file=long_pipeline_runs.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${long_pipeline_runs_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${json_file}

    TRY
        ${long_runs}=    Evaluate    json.loads(r'''${long_pipeline_runs_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${long_runs}=    Create Dictionary    long_runs=[]
    END

    ${has_long_runs}=    Evaluate    len($long_runs.get("long_running_pipelines", [])) > 0

    IF    ${has_long_runs}
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["Pipeline_Name", "Run_Id", "Duration_Sec", "Status", "Resource_URL"], (.long_running_pipelines[] | [ .name, .run_id, .duration, .status, .resource_url]) | @tsv' ${json_file} | column -t -s $'\t'
        RW.Core.Add Pre To Report    Long Running Pipeline Runs Summary:\n==============================\n${formatted_results.stdout}

        FOR    ${issue}    IN    @{long_runs["long_running_pipelines"]}
           
            RW.Core.Add Issue
            ...    severity=${issue.get("severity", 4)}
            ...    title=${issue.get("title", "No title")}
            ...    details=${issue}
            ...    next_steps=${issue.get("next_step", "No next steps")}
            ...    expected=${issue.get("expected", "No expected value")}
            ...    actual=${issue.get("actual", "No actual value")}
            ...    reproduce_hint=${issue.get("reproduce_hint", "No reproduce hint")}
        END
    ELSE
        RW.Core.Add Pre To Report    "No long running pipelines found in resource group `${AZURE_RESOURCE_GROUP}`"
    END


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
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}", "LOOKBACK_PERIOD":"${LOOKBACK_PERIOD}", "THRESHOLD_MB":"${THRESHOLD_MB}", "FAILURE_THRESHOLD":"${FAILURE_THRESHOLD}", "RUN_TIME_THRESHOLD":"${RUN_TIME_THRESHOLD}"}