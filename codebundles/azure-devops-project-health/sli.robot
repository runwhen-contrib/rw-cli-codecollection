*** Settings ***
Documentation       Cheap Azure DevOps project-health SLI. Fetches the project's builds ONCE for a short window (RW_LOOKBACK_WINDOW ~= scrape interval x1.5) and derives five binary {0,1} sub-scores — data collection OK, pipeline failure ratio within budget, no protected-branch pipeline failing 100%, no build queued past threshold, and in-flight long-running builds within budget — then averages them into a primary health score between 0 (failing) and 1 (healthy). Designed to run every ~30 min and to recover within ~one interval once a transient failure ages out of the window. Its SLO breach triggers this SLX's investigation runbook.
Metadata            Author    runwhen
Metadata            Display Name    Azure DevOps Project Health SLI
Metadata            Supports    Azure    DevOps    Projects    Health    SLI

Library             String
Library             BuiltIn
Library             Collections
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Score Azure DevOps Project Pipeline Health for `${AZURE_DEVOPS_PROJECT}` in `${AZURE_DEVOPS_ORG}`
    [Documentation]    Runs the single-pass build-dataset scorer and pushes the four build-derived sub-scores plus data_collection_ok. data_collection_ok = 1 only when the preflight access matrix is OK AND the build query returned a valid dataset (not an error marker); convention is "score 0 only for what we measure and confirm bad, 1 for what we cannot measure".
    [Tags]    DevOps    Azure    Pipelines    sli    access:read-only    data:metrics
    ${failure_ratio_ok}=    Set Variable    1
    ${protected_ok}=    Set Variable    1
    ${queue_ok}=    Set Variable    1
    ${long_ok}=    Set Variable    1
    ${build_query_ok}=    Set Variable    1
    ${details}=    Create Dictionary
    FOR    ${project}    IN    @{PROJECT_LIST}
        ${score_env}=    Create Dictionary
        ...    AZURE_DEVOPS_ORG=${AZURE_DEVOPS_ORG}
        ...    AZURE_DEVOPS_PROJECT=${project}
        ...    RW_LOOKBACK_WINDOW=${RW_LOOKBACK_WINDOW}
        ...    SLI_MAX_FAILURE_RATIO=${SLI_MAX_FAILURE_RATIO}
        ...    QUEUE_THRESHOLD=${QUEUE_THRESHOLD}
        ...    DURATION_THRESHOLD=${DURATION_THRESHOLD}
        ...    SLI_MAX_LONGRUNNING=${SLI_MAX_LONGRUNNING}
        ...    SLI_PROTECTED_BRANCH_PATTERN=${SLI_PROTECTED_BRANCH_PATTERN}
        ...    AUTH_TYPE=${AUTH_TYPE}
        ...    AZURE_CONFIG_DIR=${AZURE_DEVOPS_CONFIG_DIR}
        ${data}=    Create Dictionary
        ...    pipeline_failure_ratio_ok=1    protected_branch_failures_ok=1
        ...    queue_aging_ok=1    long_running_ok=1    build_query_ok=0    details=${{ {} }}
        TRY
            ${out}=    RW.CLI.Run Bash File
            ...    bash_file=sli-project-health-score.sh
            ...    env=${score_env}
            ...    secret__azure_devops_pat=${AZURE_DEVOPS_PAT}
            ...    timeout_seconds=120
            ...    include_in_history=false
            ${score_json_raw}=    RW.CLI.Run Cli
            ...    cmd=cat sli_project_health_score.json 2>/dev/null || echo '{}'
            TRY
                ${data}=    Evaluate    json.loads(r'''${score_json_raw.stdout}''')    json
            EXCEPT
                ${data}=    Evaluate    json.loads(r'''${out.stdout}''')    json
            END
        EXCEPT    AS    ${err}
            Log    Project SLI scoring failed for ${project}: ${err}    WARN
        END
        ${failure_ratio_ok}=    Evaluate    min(int(${failure_ratio_ok}), int(${data}.get('pipeline_failure_ratio_ok', 1)))    json
        ${protected_ok}=    Evaluate    min(int(${protected_ok}), int(${data}.get('protected_branch_failures_ok', 1)))    json
        ${queue_ok}=    Evaluate    min(int(${queue_ok}), int(${data}.get('queue_aging_ok', 1)))    json
        ${long_ok}=    Evaluate    min(int(${long_ok}), int(${data}.get('long_running_ok', 1)))    json
        ${build_query_ok}=    Evaluate    min(int(${build_query_ok}), int(${data}.get('build_query_ok', 0)))    json
        ${d}=    Evaluate    ${data}.get('details', {})    json
        ${ctx}=    Set Variable    Project `${project}` SLI: builds=${d.get('build_count', '-')}, failed=${d.get('failed_in_window', '-')} (ratio ${d.get('failure_ratio', '-')}), window=${d.get('window', '-')}
        RW.Core.Add To Report    ${ctx}
    END

    # data_collection_ok folds the preflight access result with the build query
    # result: both must be healthy to claim we actually measured the project.
    ${data_collection_ok}=    Evaluate    1 if (${ACCESS_OK} and int(${build_query_ok}) == 1) else 0

    Set Suite Variable    ${score_data_collection}    ${data_collection_ok}
    Set Suite Variable    ${score_failure_ratio}    ${failure_ratio_ok}
    Set Suite Variable    ${score_protected}    ${protected_ok}
    Set Suite Variable    ${score_queue}    ${queue_ok}
    Set Suite Variable    ${score_long_running}    ${long_ok}

    RW.Core.Push Metric    ${data_collection_ok}    sub_name=data_collection_ok
    RW.Core.Push Metric    ${failure_ratio_ok}    sub_name=pipeline_failure_ratio_ok
    RW.Core.Push Metric    ${protected_ok}    sub_name=protected_branch_failures_ok
    RW.Core.Push Metric    ${queue_ok}    sub_name=queue_aging_ok
    RW.Core.Push Metric    ${long_ok}    sub_name=long_running_ok

    ${summary}=    Set Variable    SLI scope `${AZURE_DEVOPS_PROJECT}` in `${AZURE_DEVOPS_ORG}`: access_ok=${ACCESS_OK}, build_query_ok=${build_query_ok}, failure_ratio_ok=${failure_ratio_ok}, protected_ok=${protected_ok}, queue_ok=${queue_ok}, long_running_ok=${long_ok}
    RW.Core.Add To Report    ${summary}

Generate Aggregate Azure DevOps Project Health Score for `${AZURE_DEVOPS_PROJECT}`
    [Documentation]    Averages the five sub-scores (data_collection_ok, pipeline_failure_ratio_ok, protected_branch_failures_ok, queue_aging_ok, long_running_ok) into the primary SLI metric. A breach of this SLI's SLO triggers this SLX's runbook for a deep, longer-window investigation.
    [Tags]    DevOps    Azure    Pipelines    sli    access:read-only    data:metrics
    ${total}=    Evaluate    int(${score_data_collection}) + int(${score_failure_ratio}) + int(${score_protected}) + int(${score_queue}) + int(${score_long_running})
    ${health_score}=    Evaluate    ${total} / 5.0
    ${health_score}=    Convert To Number    ${health_score}    2
    ${report_msg}=    Set Variable    Azure DevOps project health score: ${health_score} (data_collection=${score_data_collection}, failure_ratio_ok=${score_failure_ratio}, protected_branch_ok=${score_protected}, queue_aging_ok=${score_queue}, long_running_ok=${score_long_running})
    RW.Core.Add To Report    ${report_msg}
    RW.Core.Push Metric    ${health_score}


*** Keywords ***
Suite Initialization
    Log    Starting Project SLI Suite Initialization...    INFO

    # Support both Azure Service Principal and Azure DevOps PAT authentication
    TRY
        ${azure_credentials}=    RW.Core.Import Secret
        ...    azure_credentials
        ...    type=string
        ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
        ...    pattern=\w*
        Set Suite Variable    ${AUTH_TYPE}    service_principal
        Set Suite Variable    ${AZURE_DEVOPS_PAT}    ${EMPTY}
    EXCEPT
        Log    Azure credentials not found, trying Azure DevOps PAT...    INFO
        TRY
            ${azure_devops_pat}=    RW.Core.Import Secret
            ...    azure_devops_pat
            ...    type=string
            ...    description=Azure DevOps Personal Access Token
            ...    pattern=\w*
            Set Suite Variable    ${AUTH_TYPE}    pat
            Set Suite Variable    ${AZURE_DEVOPS_PAT}    ${azure_devops_pat}
        EXCEPT
            Log    No authentication method found, defaulting to service principal...    WARN
            Set Suite Variable    ${AUTH_TYPE}    service_principal
            Set Suite Variable    ${AZURE_DEVOPS_PAT}    ${EMPTY}
        END
    END

    ${AZURE_DEVOPS_ORG}=    RW.Core.Import User Variable    AZURE_DEVOPS_ORG
    ...    type=string
    ...    description=Azure DevOps organization name.
    ...    pattern=\w*
    ${AZURE_DEVOPS_PROJECTS}=    RW.Core.Import User Variable    AZURE_DEVOPS_PROJECTS
    ...    type=string
    ...    description=Project to score, comma-separated list, or All/empty to discover and score every project in the org (local dev). Generated SLIs set a single project name.
    ...    pattern=.*
    ...    default=All
    # Platform-injected in SLI context (seconds, derived from intervalSeconds). Do not set in the SLI template configProvided.
    TRY
        ${RW_LOOKBACK_WINDOW}=    RW.Core.Import Platform Variable    RW_LOOKBACK_WINDOW
    EXCEPT
        # Local `ro sli.robot` without platform injection: intervalSeconds 1800 × 1.5 → 45m window.
        ${RW_LOOKBACK_WINDOW}=    Set Variable    2700
    END
    ${RW_LOOKBACK_WINDOW}=    RW.Core.Normalize Lookback Window    ${RW_LOOKBACK_WINDOW}    2
    ${SLI_MAX_FAILURE_RATIO}=    RW.Core.Import User Variable    SLI_MAX_FAILURE_RATIO
    ...    type=string
    ...    description=Maximum failed/total completed-build ratio in the window before pipeline_failure_ratio_ok drops to 0. 0 runs in the window scores 1 (cannot measure = healthy).
    ...    default=0.50
    ...    pattern=^\d*\.?\d+$
    ${QUEUE_THRESHOLD}=    RW.Core.Import User Variable    QUEUE_THRESHOLD
    ...    type=string
    ...    description=A build queued (notStarted) longer than this drops queue_aging_ok to 0 (point-in-time). Format: 30m, 1h.
    ...    default=30m
    ...    pattern=\w*
    ${DURATION_THRESHOLD}=    RW.Core.Import User Variable    DURATION_THRESHOLD
    ...    type=string
    ...    description=In-flight builds running longer than this are counted as long-running (point-in-time). Format: 60m, 2h.
    ...    default=60m
    ...    pattern=\w*
    ${SLI_MAX_LONGRUNNING}=    RW.Core.Import User Variable    SLI_MAX_LONGRUNNING
    ...    type=string
    ...    description=Maximum number of in-flight long-running builds allowed before long_running_ok drops to 0.
    ...    default=1
    ...    pattern=^\d+$
    ${SLI_PROTECTED_BRANCH_PATTERN}=    RW.Core.Import User Variable    SLI_PROTECTED_BRANCH_PATTERN
    ...    type=string
    ...    description=Regex matching protected source branches. protected_branch_failures_ok scores 0 only when a pipeline on one of these branches fails 100% of its runs in the window.
    ...    default=^refs/heads/(main|master|develop|release/)
    ...    pattern=.*

    # Resolve project scope: empty or All => discover every project (same as runbook).
    ${projects_trimmed}=    Strip String    ${AZURE_DEVOPS_PROJECTS}
    ${is_all}=    Evaluate    "${projects_trimmed}".lower() in ("", "all")
    IF    ${is_all}
        Log    AZURE_DEVOPS_PROJECTS empty/All — discovering all projects in organization...    INFO
        ${PROJECT_LIST}=    Discover All Projects
    ELSE
        ${PROJECT_LIST}=    Split String    ${projects_trimmed}    ,
        ${cleaned_projects}=    Create List
        FOR    ${project}    IN    @{PROJECT_LIST}
            ${project_trimmed}=    Strip String    ${project}
            IF    "${project_trimmed}" != ""
                Append To List    ${cleaned_projects}    ${project_trimmed}
            END
        END
        ${PROJECT_LIST}=    Set Variable    ${cleaned_projects}
    END
    ${project_count}=    Get Length    ${PROJECT_LIST}
    IF    ${project_count} == 0
        Fail    No projects found or accessible in organization ${AZURE_DEVOPS_ORG}. Set AZURE_DEVOPS_PROJECTS to a project name, All, or leave empty to auto-discover.
    END
    IF    ${project_count} == 1
        ${AZURE_DEVOPS_PROJECT}=    Set Variable    ${PROJECT_LIST}[0]
    ELSE
        ${AZURE_DEVOPS_PROJECT}=    Evaluate    str(len($PROJECT_LIST)) + " projects"
    END
    ${projects_csv}=    Evaluate    ",".join($PROJECT_LIST)

    Set Suite Variable    ${AZURE_DEVOPS_ORG}    ${AZURE_DEVOPS_ORG}
    Set Suite Variable    ${PROJECT_LIST}    ${PROJECT_LIST}
    Set Suite Variable    ${AZURE_DEVOPS_PROJECT}    ${AZURE_DEVOPS_PROJECT}
    Set Suite Variable    ${RW_LOOKBACK_WINDOW}    ${RW_LOOKBACK_WINDOW}
    Set Suite Variable    ${SLI_MAX_FAILURE_RATIO}    ${SLI_MAX_FAILURE_RATIO}
    Set Suite Variable    ${QUEUE_THRESHOLD}    ${QUEUE_THRESHOLD}
    Set Suite Variable    ${DURATION_THRESHOLD}    ${DURATION_THRESHOLD}
    Set Suite Variable    ${SLI_MAX_LONGRUNNING}    ${SLI_MAX_LONGRUNNING}
    Set Suite Variable    ${SLI_PROTECTED_BRANCH_PATTERN}    ${SLI_PROTECTED_BRANCH_PATTERN}
    Set Suite Variable    ${AZURE_DEVOPS_CONFIG_DIR}    %{CODEBUNDLE_TEMP_DIR}/.azure-devops

    # Preflight access check (cheap capability matrix). Drives data_collection_ok.
    ${preflight_env}=    Create Dictionary
    ...    AZURE_DEVOPS_ORG=${AZURE_DEVOPS_ORG}
    ...    AZURE_DEVOPS_PROJECTS=${projects_csv}
    ...    AUTH_TYPE=${AUTH_TYPE}
    ...    AZURE_CONFIG_DIR=${AZURE_DEVOPS_CONFIG_DIR}
    ${access_ok}=    Set Variable    ${False}
    TRY
        ${preflight}=    RW.CLI.Run Bash File
        ...    bash_file=preflight-check.sh
        ...    env=${preflight_env}
        ...    secret__azure_devops_pat=${AZURE_DEVOPS_PAT}
        ...    timeout_seconds=120
        ...    include_in_history=false
        ${preflight_json_raw}=    RW.CLI.Run Cli
        ...    cmd=cat preflight_results.json 2>/dev/null || echo '{"access_ok": false}'
        ${preflight_data}=    Evaluate    json.loads(r'''${preflight_json_raw.stdout}''')    json
        ${access_ok}=    Evaluate    bool(${preflight_data}.get('access_ok', False))
    EXCEPT    AS    ${err}
        Log    Preflight access check did not complete: ${err}    WARN
    END
    Set Suite Variable    ${ACCESS_OK}    ${access_ok}

    Log    Project SLI Suite Initialization complete (scope=${AZURE_DEVOPS_PROJECT}, projects=${PROJECT_LIST}, access_ok=${ACCESS_OK}).    INFO


Discover All Projects
    [Documentation]    Auto-discover all projects in the Azure DevOps organization (same as runbook.robot).

    ${temp_env}=    Create Dictionary
    ...    AZURE_DEVOPS_ORG=${AZURE_DEVOPS_ORG}
    ...    AUTH_TYPE=${AUTH_TYPE}
    ${discover_projects}=    RW.CLI.Run Bash File
    ...    bash_file=discover-projects.sh
    ...    env=${temp_env}
    ...    secret__azure_devops_pat=${AZURE_DEVOPS_PAT}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ${projects_result}=    RW.CLI.Run Cli
    ...    cmd=cat discovered_projects.json
    TRY
        ${projects_data}=    Evaluate    json.loads(r'''${projects_result.stdout}''')    json
        ${project_names}=    Evaluate    [project['name'] for project in ${projects_data}]
        RETURN    ${project_names}
    EXCEPT
        Log    Failed to discover projects, using fallback method...    WARN
        ${project_lines}=    Split To Lines    ${discover_projects.stdout}
        ${project_names}=    Create List
        FOR    ${line}    IN    @{project_lines}
            ${line}=    Strip String    ${line}
            IF    "${line}" != "" and not "${line}".startswith("#") and not "${line}".startswith("Analyzing")
                Append To List    ${project_names}    ${line}
            END
        END
        RETURN    ${project_names}
    END
