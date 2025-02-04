*** Settings ***
Documentation       This taskset runs a user provided kubectl command and pushes the metric. The supplied command must result in distinct single metric. Command line tools like jq are available. 
Metadata            Author    stewartshea

Library             BuiltIn
Library             RW.Core
Library             RW.platform
Library             OperatingSystem
Library             RW.CLI

Suite Setup         Suite Initialization


*** Tasks ***
Run User Provided Kubectl Command in Kubernetes Cluster `$${KUBECTL_CLUSTER}`
    [Documentation]    Runs a user provided kubectl command and pushes the metric as an SLI
    [Tags]    kubectl    cli    metric    sli
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBECTL_COMMAND}
    ...    env={"KUBECONFIG":"./${kubeconfig.key}"}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Push Metric    ${rsp.stdout}

*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${KUBECTL_COMMAND}=    RW.Core.Import User Variable    KUBECTL_COMMAND
    ...    type=string
    ...    description=The kubectl command to run. Must produce a single value that can be pushed as a metric. Can use tools like jq. 
    ...    pattern=\w*
    ...    example="kubectl get pods -n online-boutique -o json | jq '[.items[]] | length"