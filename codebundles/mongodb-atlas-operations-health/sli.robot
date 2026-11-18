*** Settings ***
Documentation       Measures MongoDB Atlas project operations health as the mean of three binary signals — no OPEN/TRACKING alerts in the first alerts page for scoped clusters, backup enabled on scoped dedicated clusters, and no open CIDR or empty-allowlist/public-SRV mismatch — producing a 0–1 score for alerting.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    MongoDB Atlas Operations Health SLI
Metadata            Supports    mongodb_atlas    atlas    operations    sli

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization

*** Keywords ***
Suite Initialization
    TRY
        ${atlas_api_key_credentials}=    RW.Core.Import Secret    atlas_api_key_credentials
        ...    type=string
        ...    description=MongoDB Atlas API key pair as JSON or KEY=value text with ATLAS_PUBLIC_API_KEY and ATLAS_PRIVATE_API_KEY
        ...    pattern=\w*
        Set Suite Variable    ${atlas_api_key_credentials}    ${atlas_api_key_credentials}
    EXCEPT
        Log    atlas_api_key_credentials secret missing; SLI will score 0 dimensions.    WARN
        Set Suite Variable    ${atlas_api_key_credentials}    ${EMPTY}
    END

    ${ATLAS_PROJECT_ID}=    RW.Core.Import User Variable    ATLAS_PROJECT_ID
    ...    type=string
    ...    description=MongoDB Atlas project (group) identifier.
    ...    pattern=\w+
    ${ATLAS_ORG_ID}=    RW.Core.Import User Variable    ATLAS_ORG_ID
    ...    type=string
    ...    description=Optional Atlas organization id (reserved for future checks).
    ...    pattern=^[a-fA-F0-9]*$
    ...    default=
    ${CLUSTER_FILTER}=    RW.Core.Import User Variable    CLUSTER_FILTER
    ...    type=string
    ...    description=Comma-separated cluster names to scope SLI sampling.
    ...    pattern=^[\w[:space:],.-]*$
    ...    default=

    Set Suite Variable    ${ATLAS_PROJECT_ID}    ${ATLAS_PROJECT_ID}
    Set Suite Variable    ${ATLAS_ORG_ID}    ${ATLAS_ORG_ID}
    Set Suite Variable    ${CLUSTER_FILTER}    ${CLUSTER_FILTER}

    ${env}=    Create Dictionary
    ...    ATLAS_PROJECT_ID=${ATLAS_PROJECT_ID}
    ...    ATLAS_ORG_ID=${ATLAS_ORG_ID}
    ...    CLUSTER_FILTER=${CLUSTER_FILTER}
    Set Suite Variable    ${env}    ${env}

    Set Suite Variable    ${score_alerts}    0
    Set Suite Variable    ${score_backup}    0
    Set Suite Variable    ${score_network}    0

*** Tasks ***
Score Atlas Open Alert Posture
    [Documentation]    Binary 1 when the first page of GET alerts shows no OPEN or TRACKING items for clusters matching CLUSTER_FILTER.
    [Tags]    mongodb_atlas    sli    access:read-only    data:metrics

    ${out}=    RW.CLI.Run Bash File
    ...    bash_file=sli-atlas-alerts-score.sh
    ...    env=${env}
    ...    secret__atlas_api_key_credentials=${atlas_api_key_credentials}
    ...    include_in_history=false
    ...    timeout_seconds=45
    ...    cmd_override=ATLAS_PROJECT_ID="${ATLAS_PROJECT_ID}" ./sli-atlas-alerts-score.sh
    TRY
        ${data}=    Evaluate    json.loads(r'''${out.stdout}''')    json
    EXCEPT
        Log    SLI alerts JSON parse failed; scoring 0.    WARN
        ${data}=    Create Dictionary    score=0
    END
    ${s}=    Set Variable    ${data.get('score', 0)}
    Set Suite Variable    ${score_alerts}    ${s}
    RW.Core.Push Metric    ${s}    sub_name=atlas_alerts_clear

Score Atlas Dedicated Backup Coverage
    [Documentation]    Binary 1 when every scoped REPLICA_SET, SHARDED, or GEOSHARDED cluster reports backupEnabled or providerBackupEnabled.
    [Tags]    mongodb_atlas    sli    access:read-only    data:metrics

    ${out}=    RW.CLI.Run Bash File
    ...    bash_file=sli-atlas-backup-score.sh
    ...    env=${env}
    ...    secret__atlas_api_key_credentials=${atlas_api_key_credentials}
    ...    include_in_history=false
    ...    timeout_seconds=45
    ...    cmd_override=ATLAS_PROJECT_ID="${ATLAS_PROJECT_ID}" ./sli-atlas-backup-score.sh
    TRY
        ${data}=    Evaluate    json.loads(r'''${out.stdout}''')    json
    EXCEPT
        Log    SLI backup JSON parse failed; scoring 0.    WARN
        ${data}=    Create Dictionary    score=0
    END
    ${s}=    Set Variable    ${data.get('score', 0)}
    Set Suite Variable    ${score_backup}    ${s}
    RW.Core.Push Metric    ${s}    sub_name=atlas_backup_ok

Score Atlas Project Network Baseline
    [Documentation]    Binary 1 when no 0.0.0.0/0 allowlist entry exists and the empty-list/public-SRV heuristic from the runbook is not triggered.
    [Tags]    mongodb_atlas    sli    access:read-only    data:metrics

    ${out}=    RW.CLI.Run Bash File
    ...    bash_file=sli-atlas-network-score.sh
    ...    env=${env}
    ...    secret__atlas_api_key_credentials=${atlas_api_key_credentials}
    ...    include_in_history=false
    ...    timeout_seconds=45
    ...    cmd_override=ATLAS_PROJECT_ID="${ATLAS_PROJECT_ID}" ./sli-atlas-network-score.sh
    TRY
        ${data}=    Evaluate    json.loads(r'''${out.stdout}''')    json
    EXCEPT
        Log    SLI network JSON parse failed; scoring 0.    WARN
        ${data}=    Create Dictionary    score=0
    END
    ${s}=    Set Variable    ${data.get('score', 0)}
    Set Suite Variable    ${score_network}    ${s}
    RW.Core.Push Metric    ${s}    sub_name=atlas_network_ok

Generate Aggregate Atlas Operations Health Score
    [Documentation]    Averages the three binary operations sub-scores into the primary SLI metric.
    [Tags]    mongodb_atlas    sli    access:read-only    data:metrics

    ${total}=    Evaluate    int(${score_alerts}) + int(${score_backup}) + int(${score_network})
    ${health_score}=    Evaluate    ${total} / 3.0
    ${health_score}=    Convert To Number    ${health_score}    2
    RW.Core.Add To Report    MongoDB Atlas operations health score: ${health_score} (alerts=${score_alerts}, backup=${score_backup}, network=${score_network})
    RW.Core.Push Metric    ${health_score}
