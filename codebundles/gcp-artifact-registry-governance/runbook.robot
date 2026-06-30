*** Settings ***
Documentation       Inspect GCP Artifact Registry repositories for stale images, missing cleanup policies, and legacy GCR usage to control storage spend.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Artifact Registry Governance & Cleanup
Metadata            Supports    GCP    Artifact Registry    Docker    Governance    Cleanup    Storage
Force Tags          GCP    Artifact Registry    Governance    Cleanup    Storage

Library             BuiltIn
Library             String
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Discover Artifact Registry Repositories in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Lists Artifact Registry repositories across configured locations and captures format, size estimates, and metadata for downstream governance checks.
    [Tags]    GCP    Artifact Registry    Discovery    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=discover-artifact-repositories.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./discover-artifact-repositories.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat discover_repositories_issues.json
    ...    env=${env}
    ...    timeout_seconds=30

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for discovery task, defaulting to empty list.    WARN
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

    RW.Core.Add Pre To Report    Discovery Results:
    RW.Core.Add Pre To Report    ${result.stdout}

Check Cleanup Policy Configuration for Repositories in `${GCP_PROJECT_ID}`
    [Documentation]    Verifies Docker/OCI repositories have cleanup policies covering untagged manifests and aged tags.
    [Tags]    GCP    Artifact Registry    Cleanup Policy    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-cleanup-policies.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-cleanup-policies.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat cleanup_policy_issues.json
    ...    env=${env}
    ...    timeout_seconds=30

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for cleanup policy task, defaulting to empty list.    WARN
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

    RW.Core.Add Pre To Report    Cleanup Policy Analysis:
    RW.Core.Add Pre To Report    ${result.stdout}

Identify Stale Container Images in `${GCP_PROJECT_ID}`
    [Documentation]    Finds tagged images not updated within STALE_IMAGE_THRESHOLD_DAYS and estimates storage impact by repository.
    [Tags]    GCP    Artifact Registry    Stale Images    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=identify-stale-images.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=240
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=STALE_IMAGE_THRESHOLD_DAYS=${STALE_IMAGE_THRESHOLD_DAYS} ./identify-stale-images.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat stale_images_issues.json
    ...    env=${env}
    ...    timeout_seconds=30

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for stale image task, defaulting to empty list.    WARN
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

    RW.Core.Add Pre To Report    Stale Image Analysis:
    RW.Core.Add Pre To Report    ${result.stdout}

Identify Untagged Images Consuming Storage in `${GCP_PROJECT_ID}`
    [Documentation]    Detects untagged or dangling manifests that accumulate storage cost and recommends cleanup policy rules.
    [Tags]    GCP    Artifact Registry    Untagged Images    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=identify-untagged-images.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=240
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=UNTAGGED_IMAGE_THRESHOLD_DAYS=${UNTAGGED_IMAGE_THRESHOLD_DAYS} ./identify-untagged-images.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat untagged_images_issues.json
    ...    env=${env}
    ...    timeout_seconds=30

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for untagged image task, defaulting to empty list.    WARN
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

    RW.Core.Add Pre To Report    Untagged Image Analysis:
    RW.Core.Add Pre To Report    ${result.stdout}

Detect Legacy Container Registry Usage in `${GCP_PROJECT_ID}`
    [Documentation]    Inventories gcr.io images still hosted in legacy Container Registry and flags migration and operational risk.
    [Tags]    GCP    Artifact Registry    Legacy GCR    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=detect-legacy-gcr-usage.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./detect-legacy-gcr-usage.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat legacy_gcr_issues.json
    ...    env=${env}
    ...    timeout_seconds=30

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for legacy GCR task, defaulting to empty list.    WARN
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

    RW.Core.Add Pre To Report    Legacy GCR Analysis:
    RW.Core.Add Pre To Report    ${result.stdout}

Report Artifact Registry Storage Utilization by Repository in `${GCP_PROJECT_ID}`
    [Documentation]    Summarizes image counts, tag counts, and estimated storage per repository and highlights repositories above STORAGE_UTILIZATION_THRESHOLD_GB.
    [Tags]    GCP    Artifact Registry    Storage    Metrics    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=report-repository-storage-utilization.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=240
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=STORAGE_UTILIZATION_THRESHOLD_GB=${STORAGE_UTILIZATION_THRESHOLD_GB} ./report-repository-storage-utilization.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat storage_utilization_issues.json
    ...    env=${env}
    ...    timeout_seconds=30

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for storage utilization task, defaulting to empty list.    WARN
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

    ${report}=    RW.CLI.Run Cli
    ...    cmd=cat storage_utilization_report.json
    ...    env=${env}
    ...    timeout_seconds=30

    RW.Core.Add Pre To Report    Storage Utilization Report:
    RW.Core.Add Pre To Report    ${report.stdout}
    RW.Core.Add Pre To Report    ${result.stdout}

Generate Artifact Registry Cleanup Policy Recommendations for `${GCP_PROJECT_ID}`
    [Documentation]    Produces repository-specific cleanup policy YAML suggestions based on stale and untagged findings; read-only and does not apply policies.
    [Tags]    GCP    Artifact Registry    Recommendations    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=generate-cleanup-policy-recommendations.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=MIN_TAGS_TO_KEEP=${MIN_TAGS_TO_KEEP} ./generate-cleanup-policy-recommendations.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat cleanup_policy_recommendations_issues.json
    ...    env=${env}
    ...    timeout_seconds=30

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for cleanup recommendation task, defaulting to empty list.    WARN
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

    ${recommendations}=    RW.CLI.Run Cli
    ...    cmd=cat cleanup_policy_recommendations.json
    ...    env=${env}
    ...    timeout_seconds=30

    RW.Core.Add Pre To Report    Cleanup Policy Recommendations:
    RW.Core.Add Pre To Report    ${recommendations.stdout}


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

    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable    ${ARTIFACT_REGISTRY_LOCATIONS}    ${ARTIFACT_REGISTRY_LOCATIONS}
    Set Suite Variable    ${ARTIFACT_REGISTRY_REPOSITORIES}    ${ARTIFACT_REGISTRY_REPOSITORIES}
    Set Suite Variable    ${ARTIFACT_REGISTRY_LOCATION}    ${ARTIFACT_REGISTRY_LOCATION}
    Set Suite Variable    ${ARTIFACT_REGISTRY_REPOSITORY}    ${ARTIFACT_REGISTRY_REPOSITORY}
    Set Suite Variable    ${STALE_IMAGE_THRESHOLD_DAYS}    ${STALE_IMAGE_THRESHOLD_DAYS}
    Set Suite Variable    ${UNTAGGED_IMAGE_THRESHOLD_DAYS}    ${UNTAGGED_IMAGE_THRESHOLD_DAYS}
    Set Suite Variable    ${STORAGE_UTILIZATION_THRESHOLD_GB}    ${STORAGE_UTILIZATION_THRESHOLD_GB}
    Set Suite Variable    ${MIN_TAGS_TO_KEEP}    ${MIN_TAGS_TO_KEEP}

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
