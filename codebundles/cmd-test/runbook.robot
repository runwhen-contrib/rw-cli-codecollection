*** Settings ***
Metadata          Author    Jonathan Funk
Documentation     This taskset smoketests the CLI codebundle setup and run process by running a bare command
Force Tags        CLI    Stdout    Command    Local
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
    ${CLI_COMMAND}=    RW.Core.Import User Variable    CLI_COMMAND
    ...    type=string
    ...    description=The CLI command to run.
    ...    pattern=\w*
    ...    example=kubectl get pods
    ${RUN_LOCAL}=    RW.Core.Import User Variable    RUN_LOCAL
    ...    type=string
    ...    description=Controls whether or not the command is run locally or uses the provided shell service.
    ...    enum=[YES,NO]
    ...    example=YES
    ...    default=YES
    Set Suite Variable    ${CLI_COMMAND}    ${CLI_COMMAND}
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}
    IF    "${RUN_LOCAL}" == "YES"
        ${kubectl}=    Evaluate    None  
    END
    Set Suite Variable    ${kubectl}    ${kubectl}

*** Tasks ***
Run CLI Command
    [Documentation]    Runs a bare CLI command and captures the stderr and stdout for the report
    [Tags]    Stdout    Test    Output    Pods
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${CLI_COMMAND}
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    Command Stdout:\n${rsp.stdout}
    RW.Core.Add Pre To Report    Command Stderr:\n${rsp.stderr}