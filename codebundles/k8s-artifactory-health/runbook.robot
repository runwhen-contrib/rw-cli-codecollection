*** Settings ***
Metadata          Author    jon-funk
Metadata          Display Name    Kubernetes Artifactory Triage
Metadata          Supports    Kubernetes,AKS,EKS,GKE,OpenShift,Artifactory
Documentation     Performs a triage on the Open Source version of Artifactory in a Kubernetes cluster.
Suite Setup       Suite Initialization
Library           BuiltIn
Library           RW.Core
Library           RW.CLI
Library           RW.platform
Library           OperatingSystem
Library           DateTime

*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${STATEFULSET_NAME}=    RW.Core.Import User Variable    STATEFULSET_NAME
    ...    type=string
    ...    description=The name of the Artifactory statefulset.
    ...    pattern=\w*
    ...    example=artifactory-oss
    ...    default=artifactory-oss
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=The name of the Kubernetes namespace that the Artifactory workloads reside in.
    ...    pattern=\w*
    ...    example=artifactory
    ...    default=artifactory
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster
    ${LABELS}=    RW.Core.Import User Variable    LABELS
    ...    type=string
    ...    description=The Kubernetes labels used to fetch the first matching statefulset.
    ...    pattern=\w*
    ...    example=Could not render example.
    ...    default=
    ${EXPECTED_AVAILABILITY}=    RW.Core.Import User Variable    EXPECTED_AVAILABILITY
    ...    type=string
    ...    description=The minimum numbers of replicas allowed considered healthy.
    ...    pattern=\d+
    ...    example=2
    ...    default=2
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for CLI commands
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${STATEFULSET_NAME}    ${STATEFULSET_NAME}
    Set Suite Variable    ${EXPECTED_AVAILABILITY}    ${EXPECTED_AVAILABILITY}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}

    # Verify cluster connectivity
    ${connectivity}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} cluster-info --context ${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=30
    IF    ${connectivity.returncode} != 0
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Kubernetes cluster should be reachable via configured kubeconfig and context `${CONTEXT}`
        ...    actual=Unable to connect to Kubernetes cluster with context `${CONTEXT}`
        ...    title=Kubernetes Cluster Connectivity Check Failed for Context `${CONTEXT}`
        ...    reproduce_hint=${KUBERNETES_DISTRIBUTION_BINARY} cluster-info --context ${CONTEXT}
        ...    details=Failed to connect to the Kubernetes cluster. This may indicate an expired kubeconfig, network connectivity issues, or the cluster being unreachable.\n\nSTDOUT:\n${connectivity.stdout}\n\nSTDERR:\n${connectivity.stderr}
        ...    next_steps=Verify kubeconfig is valid and not expired\nCheck network connectivity to the cluster API server\nVerify the context '${CONTEXT}' is correctly configured\nCheck if the cluster is running and accessible
        BuiltIn.Fatal Error    Kubernetes cluster connectivity check failed for context '${CONTEXT}'. Aborting suite.
    END
    IF    "${LABELS}" != ""
        ${LABELS}=    Set Variable    -l ${LABELS}
    END
    Set Suite Variable    ${LABELS}    ${LABELS}


*** Tasks ***
Check Artifactory Liveness and Readiness Endpoints in `NAMESPACE`
    [Documentation]    Runs a set of exec commands internally in the Artifactory workloads to curl the system health endpoints.
    [Tags]    Pods    Statefulset    Artifactory    Health    System    Curl    API    OK    HTTP    access:read-only
    # these endpoints dont respect json type headers
    ${timestamp}=    DateTime.Get Current Date
    ${liveness}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} exec statefulset/${STATEFULSET_NAME} --context=${CONTEXT} -n ${NAMESPACE} -- curl -k --max-time 10 http://localhost:8091/artifactory/api/v1/system/liveness
    ...    env=${env}
    ...    run_in_workload_with_name=
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    # Check if Artifactory liveness endpoint does not return OK
    ${not_contains_ok}=    Run Keyword And Return Status    Should Not Contain    ${liveness.stdout}    OK
    IF    ${not_contains_ok}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=The liveness endpoint should respond with OK
        ...    actual=The liveness endpoint responded with ${liveness.stdout}
        ...    title=Artifactory Liveness Endpoint Failed for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`
        ...    details=The Artifactory workload statefulset `${STATEFULSET_NAME}` in namespace `${NAMESPACE}` liveness endpoint responded with ${liveness.stdout} when it should have returned OK
        ...    reproduce_hint=Test Artifactory liveness endpoint from within the pod
        ...    next_steps=Check Artifactory pod logs and resource availability in namespace `${NAMESPACE}`
        ...    observed_at=${timestamp}
    END
    ${readiness}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} exec statefulset/${STATEFULSET_NAME} --context=${CONTEXT} -n ${NAMESPACE} -- curl -k --max-time 10 http://localhost:8091/artifactory/api/v1/system/readiness
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    # Check if Artifactory readiness endpoint does not return OK
    ${readiness_not_ok}=    Run Keyword And Return Status    Should Not Contain    ${readiness.stdout}    OK
    IF    ${readiness_not_ok}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=The readiness endpoint should respond with OK
        ...    actual=The readiness endpoint responded with ${readiness.stdout}
        ...    title=Artifactory Readiness Endpoint Failed for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`
        ...    details=The Artifactory workload statefulset `${STATEFULSET_NAME}` in namespace `${NAMESPACE}` readiness endpoint responded with ${readiness.stdout} when it should have returned OK
        ...    reproduce_hint=Test Artifactory readiness endpoint from within the pod
        ...    next_steps=Check Artifactory startup logs and database connectivity in namespace `${NAMESPACE}`
        ...    observed_at=${timestamp}
    END
    # TODO: add task to test download of artifact objects
    # TODO: figure out how to do implicit auth without passing in secrets
    # ${topology}=    RW.CLI.Run Cli
    # ...    cmd=curl -k --max-time 10 http://localhost:8091/artifactory/api/v1/system/topology/health -H 'Content-Type: application/json'
    # ...    env=${env}
    # ...    run_in_workload_with_name=statefulset/${STATEFULSET_NAME} 
    # ...    optional_namespace=${NAMESPACE}
    # ...    optional_context=${CONTEXT}
    # ...    secret_file__kubeconfig=${KUBECONFIG}
    # ...    show_in_rwl_cheatsheet=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${liveness.stdout}
    RW.Core.Add Pre To Report    ${readiness.stdout}
    # RW.Core.Add Pre To Report    ${topology.stdout}