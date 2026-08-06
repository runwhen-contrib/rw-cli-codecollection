*** Settings ***
Documentation       Measures GCP Artifact Registry spend health by scoring anomaly signals, month-over-month growth, and project spend concentration. Produces a value between 0 (failing) and 1 (fully passing).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Artifact Registry Spend Analysis
Metadata            Supports    GCP    Artifact Registry    Cost Analysis    BigQuery
Suite Setup         Suite Initialization

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections


*** Tasks ***
Check Artifact Spend Anomaly Signals for `${GCP_PROJECT_IDS}`
    [Documentation]    Scores whether recent artifact storage daily costs remain within the configured spike multiplier of the 7-day average.
    [Tags]    GCP    Artifact Registry    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=artifact-spend-sli-check.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./artifact-spend-sli-check.sh

    TRY
        ${metrics}=    Evaluate    json.loads(r'''${result.stdout}''')    json
        ${anomaly_score}=    Set Variable    ${metrics['anomaly_score']}
        ${mom_score}=    Set Variable    ${metrics['mom_score']}
        ${share_score}=    Set Variable    ${metrics['share_score']}
    EXCEPT
        Log    Failed to parse SLI metrics, defaulting scores to 0.    WARN
        ${anomaly_score}=    Set Variable    ${0}
        ${mom_score}=    Set Variable    ${0}
        ${share_score}=    Set Variable    ${0}
    END

    Set Suite Variable    ${anomaly_score}
    Set Suite Variable    ${mom_score}
    Set Suite Variable    ${share_score}
    RW.Core.Push Metric    ${anomaly_score}    sub_name=anomaly_signals

Check Artifact Spend MoM Growth for `${GCP_PROJECT_IDS}`
    [Documentation]    Scores whether artifact spend month-over-month growth stays below the configured threshold.
    [Tags]    GCP    Artifact Registry    access:read-only    data:metrics

    RW.Core.Push Metric    ${mom_score}    sub_name=mom_growth

Check Artifact Spend Project Concentration for `${GCP_PROJECT_IDS}`
    [Documentation]    Scores whether any single project exceeds the configured share of total artifact spend.
    [Tags]    GCP    Artifact Registry    access:read-only    data:metrics

    RW.Core.Push Metric    ${share_score}    sub_name=project_concentration

Generate Artifact Registry Spend Health Score for `${GCP_PROJECT_IDS}`
    [Documentation]    Averages artifact spend sub-scores into the final 0-1 health metric.
    [Tags]    GCP    Artifact Registry    access:read-only    data:metrics

    ${health_score}=    Evaluate    (${anomaly_score} + ${mom_score} + ${share_score}) / 3
    ${health_score}=    Convert To Number    ${health_score}    2
    RW.Core.Add to Report    Artifact Registry Spend Health Score: ${health_score}
    RW.Core.Push Metric    ${health_score}


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
    ${GCP_ORG_WIDE_REPORT}=    RW.Core.Import User Variable    GCP_ORG_WIDE_REPORT
    ...    type=string
    ...    description=When true, analyze org-wide artifact spend instead of filtering to GCP_PROJECT_IDS.
    ...    pattern=(true|false)
    ...    default=false
    ${OS_PATH}=    Get Environment Variable    PATH

    Set Suite Variable    ${GCP_PROJECT_IDS}    ${GCP_PROJECT_IDS}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}

    ${env_dict}=    Create Dictionary
    Set To Dictionary    ${env_dict}    GOOGLE_APPLICATION_CREDENTIALS    ./${gcp_credentials.key}
    Set To Dictionary    ${env_dict}    COST_ANALYSIS_LOOKBACK_DAYS    ${COST_ANALYSIS_LOOKBACK_DAYS}
    Set To Dictionary    ${env_dict}    ARTIFACT_COST_SPIKE_MULTIPLIER    ${ARTIFACT_COST_SPIKE_MULTIPLIER}
    Set To Dictionary    ${env_dict}    ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT    ${ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT}
    Set To Dictionary    ${env_dict}    ARTIFACT_PROJECT_COST_THRESHOLD_PERCENT    ${ARTIFACT_PROJECT_COST_THRESHOLD_PERCENT}
    Set To Dictionary    ${env_dict}    GCP_ORG_WIDE_REPORT    ${GCP_ORG_WIDE_REPORT}
    Set To Dictionary    ${env_dict}    PATH    ${OS_PATH}
    IF    $GCP_PROJECT_IDS != "" and $GCP_PROJECT_IDS != '""'
        Set To Dictionary    ${env_dict}    GCP_PROJECT_IDS    ${GCP_PROJECT_IDS}
    END
    IF    $GCP_BILLING_EXPORT_TABLE != "" and $GCP_BILLING_EXPORT_TABLE != '""'
        Set To Dictionary    ${env_dict}    GCP_BILLING_EXPORT_TABLE    ${GCP_BILLING_EXPORT_TABLE}
    END
    Set Suite Variable    ${env}    ${env_dict}
