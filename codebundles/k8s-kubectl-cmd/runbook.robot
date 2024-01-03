*** Settings ***
Documentation       This taskset runs a user provided kubectl command andadds the output to the report. Command line tools like jq are available.
Metadata            Author    stewartshea

Library             BuiltIn
Library             RW.Core
Library             RW.platform
Library             OperatingSystem
Library             RW.CLI

Suite Setup         Suite Initialization


*** Tasks ***
Run User Provided Kubectl Command
    [Documentation]    Runs a user provided kubectl command and adds the output to the report.
    [Tags]    kubectl    cli
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBECTL_COMMAND}
    ...    env={"KUBECONFIG":"./${kubeconfig.key}"}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Command stdout: ${rsp.stdout}
    RW.Core.Add Pre To Report    Command stderr: ${rsp.stderr}
    RW.Core.Add Pre To Report    Commands Used: ${history}


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
    ...    description=The kubectl command to run. Can use tools like jq.
    ...    pattern=\w*
    ...    example="kubectl describe pods -n online-boutique"
