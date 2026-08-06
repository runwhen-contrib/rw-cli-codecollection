*** Settings ***
Documentation       Analyze Google Cloud Artifact Registry and legacy Container Registry spend from BigQuery billing export to surface storage and egress trends, top contributors, anomalies, and optimization recommendations.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Artifact Registry Spend Analysis
Metadata            Supports    GCP    Artifact Registry    Container Registry    Cost Analysis    BigQuery    FinOps
Force Tags          GCP    Artifact Registry    Container Registry    Cost Analysis    BigQuery    FinOps

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections
Suite Setup         Suite Initialization


*** Tasks ***
Analyze Artifact Registry Spend by Project and SKU for `${GCP_PROJECT_IDS}`
    [Documentation]    Query BigQuery billing export filtered to Artifact Registry and legacy GCR SKUs and produce per-project, per-SKU totals with daily, weekly, and monthly rollups for the configured lookback window.
    [Tags]    GCP    Artifact Registry    Cost Analysis    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze-artifact-registry-spend.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./analyze-artifact-registry-spend.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "artifact_spend_analysis_output.json" ]; then cat artifact_spend_analysis_output.json; else echo "[]"; fi
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for analyze task, defaulting to empty list.    WARN
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

    RW.Core.Add Pre To Report    Artifact Spend Analysis:
    RW.Core.Add Pre To Report    ${result.stdout}

Report Top Artifact Registry Cost Contributors for `${GCP_PROJECT_IDS}`
    [Documentation]    Rank projects and SKUs by artifact storage and transfer spend and highlight contributors exceeding configurable share or absolute thresholds.
    [Tags]    GCP    Artifact Registry    Cost Analysis    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=report-top-artifact-cost-contributors.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./report-top-artifact-cost-contributors.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "artifact_top_contributors_output.json" ]; then cat artifact_top_contributors_output.json; else echo "[]"; fi
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for top contributors task, defaulting to empty list.    WARN
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

    RW.Core.Add Pre To Report    Top Artifact Cost Contributors:
    RW.Core.Add Pre To Report    ${result.stdout}

Compare Artifact Registry Spend Month-over-Month for `${GCP_PROJECT_IDS}`
    [Documentation]    Compare artifact-related costs across the last three complete calendar months and raise issues when month-over-month growth exceeds the configured threshold or storage grows without corresponding pull activity.
    [Tags]    GCP    Artifact Registry    Trend Analysis    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=compare-artifact-spend-mom.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./compare-artifact-spend-mom.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "artifact_mom_output.json" ]; then cat artifact_mom_output.json; else echo "[]"; fi
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for MoM task, defaulting to empty list.    WARN
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

    RW.Core.Add Pre To Report    Artifact Spend Month-over-Month:
    RW.Core.Add Pre To Report    ${result.stdout}

Detect Artifact Storage Cost Anomalies for `${GCP_PROJECT_IDS}`
    [Documentation]    Detect daily artifact storage cost spikes at multiples of the 7-day average and sustained weekly deviations from the 30-day trend for artifact SKUs only.
    [Tags]    GCP    Artifact Registry    Anomaly Detection    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=detect-artifact-cost-anomalies.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./detect-artifact-cost-anomalies.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "artifact_anomaly_output.json" ]; then cat artifact_anomaly_output.json; else echo "[]"; fi
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for anomaly task, defaulting to empty list.    WARN
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

    RW.Core.Add Pre To Report    Artifact Cost Anomalies:
    RW.Core.Add Pre To Report    ${result.stdout}

Generate Artifact Registry Spend Optimization Summary for `${GCP_PROJECT_IDS}`
    [Documentation]    Consolidate artifact spend findings into actionable recommendations for cleanup policies, legacy GCR retirement, duplicate tag reduction, and scanning right-sizing with governance bundle follow-up for high-cost projects.
    [Tags]    GCP    Artifact Registry    Cost Optimization    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=generate-artifact-spend-recommendations.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./generate-artifact-spend-recommendations.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "artifact_recommendations_output.json" ]; then cat artifact_recommendations_output.json; else echo "[]"; fi
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for recommendations task, defaulting to empty list.    WARN
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

    RW.Core.Add Pre To Report    Artifact Spend Optimization Summary:
    RW.Core.Add Pre To Report    ${result.stdout}


*** Keywords ***
Suite Initialization
    TRY
        ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
        ...    type=string
        ...    description=GCP service account JSON with BigQuery billing export read access.
        ...    pattern=\w*
        Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    EXCEPT
        Log    gcp_credentials not found, tasks may fail without authentication    WARN
        ${gcp_credentials}=    Set Variable    ${EMPTY}
        Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    END

    ${GCP_PROJECT_IDS}=    RW.Core.Import User Variable    GCP_PROJECT_IDS
    ...    type=string
    ...    description=Comma-separated GCP project IDs to analyze; blank auto-discovers from billing export.
    ...    pattern=[\w,-]*
    ...    default=""
    ${GCP_BILLING_EXPORT_TABLE}=    RW.Core.Import User Variable    GCP_BILLING_EXPORT_TABLE
    ...    type=string
    ...    description=BigQuery billing export table path (auto-discovered if unset).
    ...    pattern=.*
    ...    default=""
    ${COST_ANALYSIS_LOOKBACK_DAYS}=    RW.Core.Import User Variable    COST_ANALYSIS_LOOKBACK_DAYS
    ...    type=string
    ...    description=Days of billing history to analyze.
    ...    pattern=\d+
    ...    default=30
    ${ARTIFACT_COST_SPIKE_MULTIPLIER}=    RW.Core.Import User Variable    ARTIFACT_COST_SPIKE_MULTIPLIER
    ...    type=string
    ...    description=Daily cost spike threshold as multiple of 7-day average.
    ...    pattern=[0-9.]+
    ...    default=2
    ${ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT}=    RW.Core.Import User Variable    ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT
    ...    type=string
    ...    description=Month-over-month growth percentage that triggers an issue.
    ...    pattern=\d+
    ...    default=25
    ${ARTIFACT_PROJECT_COST_THRESHOLD_PERCENT}=    RW.Core.Import User Variable    ARTIFACT_PROJECT_COST_THRESHOLD_PERCENT
    ...    type=string
    ...    description=Project share of total artifact spend that triggers an issue; 0 disables.
    ...    pattern=\d+
    ...    default=20
    ${OUTPUT_FORMAT}=    RW.Core.Import User Variable    OUTPUT_FORMAT
    ...    type=string
    ...    description=Report format table, csv, json, or all.
    ...    pattern=\w+
    ...    default=table
    ${GCP_ORG_WIDE_REPORT}=    RW.Core.Import User Variable    GCP_ORG_WIDE_REPORT
    ...    type=string
    ...    description=When true, analyze org-wide artifact spend instead of filtering to GCP_PROJECT_IDS.
    ...    pattern=(true|false)
    ...    default=false
    ${OS_PATH}=    Get Environment Variable    PATH

    Set Suite Variable    ${GCP_PROJECT_IDS}    ${GCP_PROJECT_IDS}
    Set Suite Variable    ${GCP_BILLING_EXPORT_TABLE}    ${GCP_BILLING_EXPORT_TABLE}
    Set Suite Variable    ${COST_ANALYSIS_LOOKBACK_DAYS}    ${COST_ANALYSIS_LOOKBACK_DAYS}
    Set Suite Variable    ${ARTIFACT_COST_SPIKE_MULTIPLIER}    ${ARTIFACT_COST_SPIKE_MULTIPLIER}
    Set Suite Variable    ${ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT}    ${ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT}
    Set Suite Variable    ${ARTIFACT_PROJECT_COST_THRESHOLD_PERCENT}    ${ARTIFACT_PROJECT_COST_THRESHOLD_PERCENT}
    Set Suite Variable    ${OUTPUT_FORMAT}    ${OUTPUT_FORMAT}
    Set Suite Variable    ${GCP_ORG_WIDE_REPORT}    ${GCP_ORG_WIDE_REPORT}

    ${env_dict}=    Create Dictionary
    Set To Dictionary    ${env_dict}    GOOGLE_APPLICATION_CREDENTIALS    ./${gcp_credentials.key}
    Set To Dictionary    ${env_dict}    COST_ANALYSIS_LOOKBACK_DAYS    ${COST_ANALYSIS_LOOKBACK_DAYS}
    Set To Dictionary    ${env_dict}    ARTIFACT_COST_SPIKE_MULTIPLIER    ${ARTIFACT_COST_SPIKE_MULTIPLIER}
    Set To Dictionary    ${env_dict}    ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT    ${ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT}
    Set To Dictionary    ${env_dict}    ARTIFACT_PROJECT_COST_THRESHOLD_PERCENT    ${ARTIFACT_PROJECT_COST_THRESHOLD_PERCENT}
    Set To Dictionary    ${env_dict}    OUTPUT_FORMAT    ${OUTPUT_FORMAT}
    Set To Dictionary    ${env_dict}    GCP_ORG_WIDE_REPORT    ${GCP_ORG_WIDE_REPORT}
    Set To Dictionary    ${env_dict}    PATH    ${OS_PATH}
    IF    $GCP_PROJECT_IDS != "" and $GCP_PROJECT_IDS != '""'
        Set To Dictionary    ${env_dict}    GCP_PROJECT_IDS    ${GCP_PROJECT_IDS}
    END
    IF    $GCP_BILLING_EXPORT_TABLE != "" and $GCP_BILLING_EXPORT_TABLE != '""'
        Set To Dictionary    ${env_dict}    GCP_BILLING_EXPORT_TABLE    ${GCP_BILLING_EXPORT_TABLE}
    END
    Set Suite Variable    ${env}    ${env_dict}
