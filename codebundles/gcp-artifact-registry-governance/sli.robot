*** Settings ***
Documentation       Measures GCP Artifact Registry governance health by scoring cleanup policies, stale images, untagged manifests, and storage utilization. Produces a value between 0 (failing) and 1 (fully passing).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Artifact Registry Governance SLI
Metadata            Supports    GCP    Artifact Registry    Governance    Cleanup    Storage
Force Tags          GCP    Artifact Registry    Governance    SLI

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Check Cleanup Policy Configuration Score for Repository in `${GCP_PROJECT_ID}`
    [Documentation]    Scores whether configured cleanup policies pass governance checks.
    [Tags]    GCP    Artifact Registry    Cleanup Policy    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-cleanup-policies.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=120
    ...    include_in_history=false
    TRY
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat cleanup_policy_issues.json
        ...    env=${env}
        ...    timeout_seconds=30
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        ${cleanup_score}=    Evaluate    0 if len(@{issue_list}) > 0 else 1
    EXCEPT
        Log    Failed to parse cleanup policy issues JSON, defaulting to score 0    WARN
        ${cleanup_score}=    Set Variable    0
    END
    Set Suite Variable    ${cleanup_score}
    RW.Core.Push Metric    ${cleanup_score}    sub_name=cleanup_policy

Check Stale Image Score for Repository in `${GCP_PROJECT_ID}`
    [Documentation]    Scores whether stale tagged images are within configured thresholds.
    [Tags]    GCP    Artifact Registry    Stale Images    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=identify-stale-images.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=120
    ...    include_in_history=false
    TRY
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat stale_images_issues.json
        ...    env=${env}
        ...    timeout_seconds=30
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        ${stale_score}=    Evaluate    0 if len(@{issue_list}) > 0 else 1
    EXCEPT
        Log    Failed to parse stale image issues JSON, defaulting to score 0    WARN
        ${stale_score}=    Set Variable    0
    END
    Set Suite Variable    ${stale_score}
    RW.Core.Push Metric    ${stale_score}    sub_name=stale_images

Check Untagged Image Score for Repository in `${GCP_PROJECT_ID}`
    [Documentation]    Scores whether untagged manifests are within configured thresholds.
    [Tags]    GCP    Artifact Registry    Untagged Images    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=identify-untagged-images.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=120
    ...    include_in_history=false
    TRY
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat untagged_images_issues.json
        ...    env=${env}
        ...    timeout_seconds=30
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        ${untagged_score}=    Evaluate    0 if len(@{issue_list}) > 0 else 1
    EXCEPT
        Log    Failed to parse untagged image issues JSON, defaulting to score 0    WARN
        ${untagged_score}=    Set Variable    0
    END
    Set Suite Variable    ${untagged_score}
    RW.Core.Push Metric    ${untagged_score}    sub_name=untagged_images

Check Storage Utilization Score for Repository in `${GCP_PROJECT_ID}`
    [Documentation]    Scores whether repository storage utilization is below configured thresholds.
    [Tags]    GCP    Artifact Registry    Storage    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=report-repository-storage-utilization.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=120
    ...    include_in_history=false
    TRY
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat storage_utilization_issues.json
        ...    env=${env}
        ...    timeout_seconds=30
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        ${storage_score}=    Evaluate    0 if len(@{issue_list}) > 0 else 1
    EXCEPT
        Log    Failed to parse storage utilization issues JSON, defaulting to score 0    WARN
        ${storage_score}=    Set Variable    0
    END
    Set Suite Variable    ${storage_score}
    RW.Core.Push Metric    ${storage_score}    sub_name=storage_utilization

Generate Aggregate Artifact Registry Governance Health Score for `${GCP_PROJECT_ID}`
    [Documentation]    Averages governance sub-scores into the final 0-1 health metric.
    [Tags]    GCP    Artifact Registry    Governance    SLI    access:read-only    data:metrics
    ${health_score}=    Evaluate    (${cleanup_score} + ${stale_score} + ${untagged_score} + ${storage_score}) / 4
    ${health_score}=    Convert To Number    ${health_score}    2
    RW.Core.Add to Report    Artifact Registry Governance Health Score: ${health_score}
    RW.Core.Push Metric    ${health_score}


*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account JSON with Artifact Registry read access.
    ...    pattern=\w*
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=GCP project ID containing Artifact Registry repositories.
    ...    pattern=\w*
    ${ARTIFACT_REGISTRY_LOCATIONS}=    RW.Core.Import User Variable    ARTIFACT_REGISTRY_LOCATIONS
    ...    type=string
    ...    description=Comma-separated Artifact Registry locations or All.
    ...    pattern=.*
    ...    default=All
    ${ARTIFACT_REGISTRY_REPOSITORIES}=    RW.Core.Import User Variable    ARTIFACT_REGISTRY_REPOSITORIES
    ...    type=string
    ...    description=Optional comma-separated repository IDs to scope checks; All discovers all.
    ...    pattern=.*
    ...    default=All
    ${ARTIFACT_REGISTRY_LOCATION}=    RW.Core.Import User Variable    ARTIFACT_REGISTRY_LOCATION
    ...    type=string
    ...    description=Single Artifact Registry location when scoped to one repository SLX.
    ...    pattern=.*
    ...    default=${EMPTY}
    ${ARTIFACT_REGISTRY_REPOSITORY}=    RW.Core.Import User Variable    ARTIFACT_REGISTRY_REPOSITORY
    ...    type=string
    ...    description=Single Artifact Registry repository name when scoped to one repository SLX.
    ...    pattern=.*
    ...    default=${EMPTY}
    ${STALE_IMAGE_THRESHOLD_DAYS}=    RW.Core.Import User Variable    STALE_IMAGE_THRESHOLD_DAYS
    ...    type=string
    ...    description=Days without pull or update after which an image is considered stale.
    ...    pattern=\d+
    ...    default=90
    ${UNTAGGED_IMAGE_THRESHOLD_DAYS}=    RW.Core.Import User Variable    UNTAGGED_IMAGE_THRESHOLD_DAYS
    ...    type=string
    ...    description=Age threshold in days for untagged manifests flagged for cleanup.
    ...    pattern=\d+
    ...    default=30
    ${STORAGE_UTILIZATION_THRESHOLD_GB}=    RW.Core.Import User Variable    STORAGE_UTILIZATION_THRESHOLD_GB
    ...    type=string
    ...    description=Repository estimated storage GB that triggers utilization issue; 0 disables.
    ...    pattern=\d+
    ...    default=50
    ${MIN_TAGS_TO_KEEP}=    RW.Core.Import User Variable    MIN_TAGS_TO_KEEP
    ...    type=string
    ...    description=Recommended minimum tagged versions to retain per package.
    ...    pattern=\d+
    ...    default=5
    ${OS_PATH}=    Get Environment Variable    PATH

    Set Suite Variable    ${cleanup_score}    0
    Set Suite Variable    ${stale_score}    0
    Set Suite Variable    ${untagged_score}    0
    Set Suite Variable    ${storage_score}    0
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}

    ${env_dict}=    Create Dictionary
    ...    GCP_PROJECT_ID=${GCP_PROJECT_ID}
    ...    ARTIFACT_REGISTRY_LOCATIONS=${ARTIFACT_REGISTRY_LOCATIONS}
    ...    ARTIFACT_REGISTRY_REPOSITORIES=${ARTIFACT_REGISTRY_REPOSITORIES}
    ...    ARTIFACT_REGISTRY_LOCATION=${ARTIFACT_REGISTRY_LOCATION}
    ...    ARTIFACT_REGISTRY_REPOSITORY=${ARTIFACT_REGISTRY_REPOSITORY}
    ...    STALE_IMAGE_THRESHOLD_DAYS=${STALE_IMAGE_THRESHOLD_DAYS}
    ...    UNTAGGED_IMAGE_THRESHOLD_DAYS=${UNTAGGED_IMAGE_THRESHOLD_DAYS}
    ...    STORAGE_UTILIZATION_THRESHOLD_GB=${STORAGE_UTILIZATION_THRESHOLD_GB}
    ...    MIN_TAGS_TO_KEEP=${MIN_TAGS_TO_KEEP}
    ...    CLOUDSDK_CORE_PROJECT=${GCP_PROJECT_ID}
    ...    GOOGLE_APPLICATION_CREDENTIALS=./${gcp_credentials.key}
    ...    PATH=${OS_PATH}
    Set Suite Variable    ${env}    ${env_dict}

    RW.CLI.Run Bash File
    ...    bash_file=discover-artifact-repositories.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=120
    ...    include_in_history=false
