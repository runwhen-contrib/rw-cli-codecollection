*** Settings ***
Documentation       Measures GCP Artifact Registry spend health by scoring billing access, month-over-month growth, and daily cost anomaly signals. Produces a value between 0 (failing) and 1 (fully passing).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Artifact Registry Spend Analysis SLI
Metadata            Supports    GCP    Artifact Registry    Cost Analysis    BigQuery

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Check Artifact Billing Access and Score
    [Documentation]    Verifies BigQuery billing export access for artifact SKU queries and produces a binary access score.
    [Tags]    GCP    Artifact Registry    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sli-artifact-spend-health-score.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=60
    ...    include_in_history=false

    TRY
        ${sli_data}=    RW.CLI.Run Cli
        ...    cmd=cat sli_artifact_health.json
        ...    env=${env}
        ...    timeout_seconds=15
        ${parsed}=    Evaluate    json.loads(r'''${sli_data.stdout}''')    json
        ${access_score}=    Set Variable    ${parsed['access_score']}
        ${mom_score}=    Set Variable    ${parsed['mom_score']}
        ${anomaly_score}=    Set Variable    ${parsed['anomaly_score']}
    EXCEPT
        Log    SLI JSON parse failed, defaulting scores to 0.    WARN
        ${access_score}=    Set Variable    0
        ${mom_score}=    Set Variable    0
        ${anomaly_score}=    Set Variable    0
    END

    Set Suite Variable    ${access_score}
    Set Suite Variable    ${mom_score}
    Set Suite Variable    ${anomaly_score}
    RW.Core.Push Metric    ${access_score}    sub_name=billing_access

Check Artifact MoM Growth and Score
    [Documentation]    Scores whether artifact spend month-over-month growth stays below the configured threshold.
    [Tags]    GCP    Artifact Registry    access:read-only    data:metrics

    RW.Core.Push Metric    ${mom_score}    sub_name=mom_growth

Check Artifact Cost Anomalies and Score
    [Documentation]    Scores whether daily artifact costs stay within the configured spike multiplier of the 7-day average.
    [Tags]    GCP    Artifact Registry    access:read-only    data:metrics

    RW.Core.Push Metric    ${anomaly_score}    sub_name=cost_anomalies

Generate Artifact Spend Health Score
    [Documentation]    Averages sub-scores into the final 0-1 artifact spend health metric.
    [Tags]    GCP    Artifact Registry    access:read-only    data:metrics

    ${health_score}=    Evaluate    (${access_score} + ${mom_score} + ${anomaly_score}) / 3
    ${health_score}=    Convert To Number    ${health_score}    2
    RW.Core.Add to Report    Artifact Spend Health Score: ${health_score}
    RW.Core.Push Metric    ${health_score}


*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account JSON with BigQuery billing export read access.
    ...    pattern=\w*
    ${GCP_PROJECT_IDS}=    RW.Core.Import User Variable    GCP_PROJECT_IDS
    ...    type=string
    ...    description=Comma-separated GCP project IDs to analyze.
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
    ${OS_PATH}=    Get Environment Variable    PATH

    Set Suite Variable    ${GCP_PROJECT_IDS}    ${GCP_PROJECT_IDS}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}

    ${env_dict}=    Create Dictionary
    Set To Dictionary    ${env_dict}    GOOGLE_APPLICATION_CREDENTIALS    ./${gcp_credentials.key}
    Set To Dictionary    ${env_dict}    COST_ANALYSIS_LOOKBACK_DAYS    ${COST_ANALYSIS_LOOKBACK_DAYS}
    Set To Dictionary    ${env_dict}    ARTIFACT_COST_SPIKE_MULTIPLIER    ${ARTIFACT_COST_SPIKE_MULTIPLIER}
    Set To Dictionary    ${env_dict}    ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT    ${ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT}
    Set To Dictionary    ${env_dict}    PATH    ${OS_PATH}
    IF    $GCP_PROJECT_IDS != "" and $GCP_PROJECT_IDS != '""'
        Set To Dictionary    ${env_dict}    GCP_PROJECT_IDS    ${GCP_PROJECT_IDS}
    END
    IF    $GCP_BILLING_EXPORT_TABLE != "" and $GCP_BILLING_EXPORT_TABLE != '""'
        Set To Dictionary    ${env_dict}    GCP_BILLING_EXPORT_TABLE    ${GCP_BILLING_EXPORT_TABLE}
    END
    Set Suite Variable    ${env}    ${env_dict}
