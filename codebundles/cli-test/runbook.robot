*** Settings ***
Metadata          Author    jon-funk
Documentation     This taskset smoketests the CLI codebundle setup and run process
Suite Setup       Suite Initialization
Library           BuiltIn
Library           RW.Core
Library           RW.platform
Library           OperatingSystem
Library           RW.CLI

*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${kubectl}=    RW.Core.Import Service    kubectl
    ...    description=The location service used to interpret shell commands.
    ...    default=kubectl-service.shared
    ...    example=kubectl-service.shared
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=The name of the Kubernetes namespace to scope actions and searching to.
    ...    pattern=\w*
    ...    example=my-namespace
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}

*** Tasks ***
Run CLI and Parse Output For Issues
    [Documentation]    Fetch some output from the cluster in varying forms and run tests against it
    [Tags]    Stdout    Test    Output    Pods
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=kubectl get pods --context ${CONTEXT} -n ${NAMESPACE}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    # TODO: remove double slashes and find WYSIWYG method for regex passing
    ${regexp}=    Evaluate   r'(?P<pod_name>[\\w-]+)\\s+[\\w//]+\\s+(?P<pod_status>\\w+)\\s+(?P<pod_restarts>[\\d]+)'
    ${rsp}=    RW.CLI.Parse Cli Output By Line
    ...    rsp=${rsp}
    ...    lines_like_regexp=${regexp}
    ...    set_severity_level=1
    ...    set_issue_expected=No crashloops or errors in the output $_stdout!
    ...    set_issue_actual=We found crashloops in the output line $_line!
    ...    set_issue_reproduce_hint=Run 'kubectl get pods --context ${CONTEXT} -n ${NAMESPACE}' and check the output for crashloops
    ...    set_issue_title=The output should contain no crashloopbackoffs
    ...    pod_status__raise_issue_if_eq=CrashLoopBackOff
    ...    pod_status__raise_issue_if_eq=Error
    ...    pod_name__raise_issue_if_contains=crashi
    ...    pod_name__raise_issue_if_contains=bobbydroptables
    ...    pod_name__raise_issue_if_ncontains=Kyle
    ...    pod_restarts__raise_issue_if_gt=0
    ...    nonsense__raise_issue_if_gt=0
    ...    potatoes=0
    RW.Core.Add Pre To Report    Found issues after parsing the output of: kubectl get pods --context ${CONTEXT} -n ${NAMESPACE}

    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=kubectl get pods --context ${CONTEXT} -n ${NAMESPACE} -ojson
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${rsp}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${rsp}
    ...    set_severity_level=1
    ...    set_issue_title=Pod Restarts Detected
    ...    set_issue_actual=We found $total_container_restarts in the namespace: ${NAMESPACE}
    ...    set_issue_details=There were a total of $total_container_restarts pod restarts in the stdout of the command we ran.
    ...    extract_path_to_var__pod_names=items[*].metadata.name
    ...    extract_path_to_var__pod_count=length(items)
    ...    extract_path_to_var__total_container_restarts=sum(items[*].status.containerStatuses[*].restartCount[])
    ...    extract_path_to_var__all_data=@
    ...    from_var_with_path__all_data__to__mycount=length(@.items)
    ...    total_container_restarts__raise_issue_if_gt=0
    ...    total_container_restarts__raise_issue_if_lt=1
    RW.Core.Add Pre To Report    Found issues after parsing the output of: kubectl get pods --context ${CONTEXT} -n ${NAMESPACE} -ojson

Exec Test
    [Documentation]    Used to verify that running CLI commands in remote workloads works
    [Tags]    Remote    Exec    Command    Tags    Workload    Pod
    ${df}=    RW.CLI.Run Cli
    ...    cmd=df
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    run_in_workload_with_name=deploy/crashi
    ...    optional_namespace=${NAMESPACE}
    ...    optional_context=${CONTEXT}
    ${ls}=    RW.CLI.Run Cli
    ...    cmd=ls
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    run_in_workload_with_labels=app=crashi
    ...    optional_namespace=${NAMESPACE}
    ...    optional_context=${CONTEXT}

Local Process Test
    [Documentation]    Verifies that commands can be run locally directly within the runner
    [Tags]    Commands    Direct    Process    Local
    # run local 'ls'
    ${ls}=    RW.CLI.Run Cli
    ...    cmd=pwd
    # run local 'kubectl get pods locally'
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=kubectl get pods --context ${CONTEXT} -n ${NAMESPACE}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    # run kubectl exec locally and df in a remote pod
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=df
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    run_in_workload_with_name=deploy/crashi
    ...    optional_namespace=${NAMESPACE}
    ...    optional_context=${CONTEXT}
    # run kubectl exec locally and df in a remote pod with tags
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=df
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    run_in_workload_with_labels=app=crashi
    ...    optional_namespace=${NAMESPACE}
    ...    optional_context=${CONTEXT}