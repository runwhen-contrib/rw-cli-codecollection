*** Settings ***
Documentation       Analyze Google Cloud Artifact Registry and legacy Container Registry spend from BigQuery billing export to surface storage and egress trends, top contributors, anomalies, and optimization recommendations.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Artifact Registry Spend Analysis
Metadata            Supports    GCP    Artifact Registry    Container Registry    Cost Analysis    BigQuery    FinOps
Force Tags          GCP    Artifact Registry    Cost Analysis    BigQuery    FinOps

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
    [Documentation]    Query BigQuery billing export filtered to Artifact Registry and legacy GCR SKUs and produce per-project, per-SKU totals with daily, weekly, and monthly rollups.
    [Tags]    GCP    Artifact Registry    Cost Analysis    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze-artifact-registry-spend.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./analyze-artifact-registry-spend.sh

    RW.Core.Add Pre To Report    Analysis Results:
    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "artifact_spend_analysis_issues.json" ]; then cat artifact_spend_analysis_issues.json; else echo "[]"; fi
    ...    env=${env}
    ...    timeout_seconds=30

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

    RW.Core.Add Pre To Report    Top Contributors:
    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "top_artifact_cost_contributors_issues.json" ]; then cat top_artifact_cost_contributors_issues.json; else echo "[]"; fi
    ...    env=${env}
    ...    timeout_seconds=30

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

Compare Artifact Registry Spend Month-over-Month for `${GCP_PROJECT_IDS}`
    [Documentation]    Compare artifact-related costs across the last three complete calendar months and raise issues when month-over-month growth exceeds threshold or storage grows without pull activity.
    [Tags]    GCP    Artifact Registry    Trend Analysis    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=compare-artifact-spend-mom.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=./compare-artifact-spend-mom.sh

    RW.Core.Add Pre To Report    Month-over-Month Comparison:
    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "artifact_spend_mom_issues.json" ]; then cat artifact_spend_mom_issues.json; else echo "[]"; fi
    ...    env=${env}
    ...    timeout_seconds=30

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

Detect Artifact Storage Cost Anomalies for `${GCP_PROJECT_IDS}`
    [Documentation]    Detect daily artifact storage cost spikes at 2x the 7-day average and sustained weekly deviations from the 30-day trend for artifact SKUs only.
    [Tags]    GCP    Artifact Registry    Anomaly Detection    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=detect-artifact-cost-anomalies.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=./detect-artifact-cost-anomalies.sh

    RW.Core.Add Pre To Report    Anomaly Detection:
    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "artifact_cost_anomalies_issues.json" ]; then cat artifact_cost_anomalies_issues.json; else echo "[]"; fi
    ...    env=${env}
    ...    timeout_seconds=30

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

Generate Artifact Registry Spend Optimization Summary for `${GCP_PROJECT_IDS}`
    [Documentation]    Consolidate spend findings into actionable recommendations including cleanup policies, legacy GCR retirement, duplicate tag reduction, and scanning right-sizing.
    [Tags]    GCP    Artifact Registry    Recommendations    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=generate-artifact-spend-recommendations.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=./generate-artifact-spend-recommendations.sh

    RW.Core.Add Pre To Report    Optimization Summary:
    RW.Core.Add Pre To Report    ${result.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "artifact_spend_recommendations_issues.json" ]; then cat artifact_spend_recommendations_issues.json; else echo "[]"; fi
    ...    env=${env}
    ...    timeout_seconds=30

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


*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account JSON with BigQuery billing export read access.
    ...    pattern=\w*
    ${GCP_PROJECT_IDS}=    RW.Core.Import User Variable    GCP_PROJECT_IDS
    ...    type=string
    ...    description=Comma-separated GCP project IDs to analyze; blank auto-discovers from billing export.
    ...    pattern=[\w,-]*
    ...    default=""
    ${GCP_BILLING_EXPORT_TABLE}=    RW.Core.Import User Variable    GCP_BILLING_EXPORT_TABLE
    ...    type=string
    ...    description=BigQuery billing export table (auto-discovered if unset).
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
    ...    pattern=[\d.]+
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
    ${OS_PATH}=    Get Environment Variable    PATH

    Set Suite Variable    ${GCP_PROJECT_IDS}    ${GCP_PROJECT_IDS}
    Set Suite Variable    ${GCP_BILLING_EXPORT_TABLE}    ${GCP_BILLING_EXPORT_TABLE}
    Set Suite Variable    ${COST_ANALYSIS_LOOKBACK_DAYS}    ${COST_ANALYSIS_LOOKBACK_DAYS}
    Set Suite Variable    ${ARTIFACT_COST_SPIKE_MULTIPLIER}    ${ARTIFACT_COST_SPIKE_MULTIPLIER}
    Set Suite Variable    ${ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT}    ${ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT}
    Set Suite Variable    ${ARTIFACT_PROJECT_COST_THRESHOLD_PERCENT}    ${ARTIFACT_PROJECT_COST_THRESHOLD_PERCENT}
    Set Suite Variable    ${OUTPUT_FORMAT}    ${OUTPUT_FORMAT}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}

    ${env_dict}=    Create Dictionary
    Set To Dictionary    ${env_dict}    GOOGLE_APPLICATION_CREDENTIALS    ./${gcp_credentials.key}
    Set To Dictionary    ${env_dict}    COST_ANALYSIS_LOOKBACK_DAYS    ${COST_ANALYSIS_LOOKBACK_DAYS}
    Set To Dictionary    ${env_dict}    ARTIFACT_COST_SPIKE_MULTIPLIER    ${ARTIFACT_COST_SPIKE_MULTIPLIER}
    Set To Dictionary    ${env_dict}    ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT    ${ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT}
    Set To Dictionary    ${env_dict}    ARTIFACT_PROJECT_COST_THRESHOLD_PERCENT    ${ARTIFACT_PROJECT_COST_THRESHOLD_PERCENT}
    Set To Dictionary    ${env_dict}    OUTPUT_FORMAT    ${OUTPUT_FORMAT}
    Set To Dictionary    ${env_dict}    PATH    ${OS_PATH}
    IF    $GCP_PROJECT_IDS != "" and $GCP_PROJECT_IDS != '""'
        Set To Dictionary    ${env_dict}    GCP_PROJECT_IDS    ${GCP_PROJECT_IDS}
    END
    IF    $GCP_BILLING_EXPORT_TABLE != "" and $GCP_BILLING_EXPORT_TABLE != '""'
        Set To Dictionary    ${env_dict}    GCP_BILLING_EXPORT_TABLE    ${GCP_BILLING_EXPORT_TABLE}
    END
    Set Suite Variable    ${env}    ${env_dict}
