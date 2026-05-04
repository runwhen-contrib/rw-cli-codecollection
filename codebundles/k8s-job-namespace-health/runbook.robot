*** Settings ***
Documentation       Surfaces Kubernetes Job and CronJob health in a namespace: failed or long-running Jobs, pod events, and CronJob scheduling anomalies.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Kubernetes Namespace Job Health
Metadata            Supports    Kubernetes    Job    CronJob    batch    Namespace    Health

Library             BuiltIn
Library             String
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.K8sHelper

Suite Setup         Suite Initialization
Force Tags          Kubernetes    Job    CronJob    Namespace    Health


*** Tasks ***
Summarize Job Status in Namespace `${NAMESPACE}`
    [Documentation]    Aggregates Jobs by active, succeeded, and failed completion state and flags long-running active Jobs or elevated batch concurrency in the namespace.
    [Tags]    Kubernetes    Job    Namespace    batch    summary    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=summarize-jobs-in-namespace.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" ./summarize-jobs-in-namespace.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat summarize_jobs_issues.json
    ...    env=${env}
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse summarize_jobs_issues.json    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Jobs in namespace `${NAMESPACE}` should complete without prolonged failures or stuck active runs
            ...    actual=${issue['title']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Summarize Jobs (namespace `${NAMESPACE}`):
    RW.Core.Add Pre To Report    ${result.stdout}

Identify Failed Jobs and Backoff in Namespace `${NAMESPACE}`
    [Documentation]    Lists Jobs in Failed condition, backoff exhaustion, and Job pods with container waiting or non-zero exit states.
    [Tags]    Kubernetes    Job    failed    backoff    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=list-failed-jobs-in-namespace.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" ./list-failed-jobs-in-namespace.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat list_failed_jobs_issues.json
    ...    env=${env}
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse list_failed_jobs_issues.json    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Jobs should not remain failed or exceed backoff without triage
            ...    actual=${issue['title']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Failed Job analysis (namespace `${NAMESPACE}`):
    RW.Core.Add Pre To Report    ${result.stdout}

Correlate Job Failures with Recent Events in Namespace `${NAMESPACE}`
    [Documentation]    Collects warning and failure-oriented events for pods owned by Jobs within the configured lookback window.
    [Tags]    Kubernetes    Job    events    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=job-failure-events-in-namespace.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" ./job-failure-events-in-namespace.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat job_failure_events_issues.json
    ...    env=${env}
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse job_failure_events_issues.json    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Job pods should not accumulate warning events during steady-state runs
            ...    actual=${issue['title']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Job pod events (namespace `${NAMESPACE}`):
    RW.Core.Add Pre To Report    ${result.stdout}

Check CronJob Schedule Health in Namespace `${NAMESPACE}`
    [Documentation]    Flags suspended CronJobs, schedules that ran recently without a recorded success, and CronJobs whose latest child Job failed.
    [Tags]    Kubernetes    CronJob    schedule    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=cronjob-schedule-health-in-namespace.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" ./cronjob-schedule-health-in-namespace.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat cronjob_health_issues.json
    ...    env=${env}
    ...    include_in_history=false
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse cronjob_health_issues.json    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=CronJobs should run on schedule with successful completions when not suspended
            ...    actual=${issue['title']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    CronJob schedule health (namespace `${NAMESPACE}`):
    RW.Core.Add Pre To Report    ${result.stdout}


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=Kubeconfig with list/get on jobs, cronjobs, pods, and events in the target namespace.
    ...    pattern=\w*
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Kubernetes CLI binary (kubectl or oc).
    ...    pattern=\w*
    ...    enum=[kubectl,oc]
    ...    default=kubectl
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Kubernetes context for API calls.
    ...    pattern=\w*
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=Namespace whose Job and CronJob health is evaluated.
    ...    pattern=\w*
    ${RW_LOOKBACK_WINDOW}=    RW.Core.Import User Variable    RW_LOOKBACK_WINDOW
    ...    type=string
    ...    description=Lookback window for events and CronJob freshness (e.g. 24h, 30m).
    ...    pattern=\w*
    ...    default=24h
    ${JOB_ACTIVE_DURATION_WARN_MINUTES}=    RW.Core.Import User Variable    JOB_ACTIVE_DURATION_WARN_MINUTES
    ...    type=string
    ...    description=Flag active Jobs running longer than this many minutes.
    ...    pattern=^\d+$
    ...    default=360
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${RW_LOOKBACK_WINDOW}    ${RW_LOOKBACK_WINDOW}
    Set Suite Variable    ${JOB_ACTIVE_DURATION_WARN_MINUTES}    ${JOB_ACTIVE_DURATION_WARN_MINUTES}
    ${env}=    Create Dictionary
    ...    KUBECONFIG=./${kubeconfig.key}
    ...    CONTEXT=${CONTEXT}
    ...    NAMESPACE=${NAMESPACE}
    ...    KUBERNETES_DISTRIBUTION_BINARY=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    RW_LOOKBACK_WINDOW=${RW_LOOKBACK_WINDOW}
    ...    JOB_ACTIVE_DURATION_WARN_MINUTES=${JOB_ACTIVE_DURATION_WARN_MINUTES}
    Set Suite Variable    ${env}    ${env}
    RW.K8sHelper.Verify Cluster Connectivity
    ...    binary=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    context=${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
