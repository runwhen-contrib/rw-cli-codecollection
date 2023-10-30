*** Settings ***
Documentation       This taskset smoketests the CLI codebundle setup and run process by running a bare command
Metadata            Author    jon-funk

Library             BuiltIn
Library             RW.Core
Library             RW.platform
Library             OperatingSystem
Library             RW.CLI
Library             RW.NextSteps

Suite Setup         Suite Initialization


*** Tasks ***
Run CLI Command
    [Documentation]    Runs a bare CLI command and captures the stderr and stdout for the report
    [Tags]    stdout    test    output    pods
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${CLI_COMMAND}
    ...    env={"KUBECONFIG":"./${kubeconfig.key}"}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    Command Stdout:\n${rsp.stdout}
    RW.Core.Add Pre To Report    Command Stderr:\n${rsp.stderr}

Run Bash File
    [Documentation]    Runs a bash file to verify script passthrough works
    [Tags]    file    script
    ${rsp}=    RW.CLI.Run Bash File
    ...    bash_file=getdeploys.sh
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    env=${env}
    RW.Core.Add Pre To Report    Command Stdout:\n${rsp.stdout}
    RW.Core.Add Pre To Report    Command Stderr:\n${rsp.stderr}

Log Suggestion
    [Documentation]    Generate a next step suggestion, format it, and log it
    ${next_steps}=    RW.NextSteps.Suggest    Bind Mount
    ${next_steps}=    RW.NextSteps.Format    ${next_steps}
    ...    pvc_name=cartservicestorage
    RW.Core.Add Pre To Report    ${next_steps}

    ${next_steps}=    RW.NextSteps.Suggest    Useless Error Message
    ${next_steps}=    RW.NextSteps.Format    ${next_steps}
    ...    blah=foo
    RW.Core.Add Pre To Report    ${next_steps}

    ${next_steps}=    RW.NextSteps.Suggest    HTTP 500 errors found in logs
    # pretend to fetch ingress name
    ${db_name}=    RW.CLI.Run Cli
    ...    cmd=echo "online-boutique"
    ${next_steps}=    RW.NextSteps.Format    ${next_steps}
    ...    ingress_name=online-boutique
    RW.Core.Add Pre To Report    ${next_steps}

    # simulate a connection err pulled from API logs
    ${next_steps}=    RW.NextSteps.Suggest    OperationalError: FATAL: connection limit exceeded for non-superusers
    # simulate fetch object name from k8s api
    ${db_name}=    RW.CLI.Run Cli
    ...    cmd=echo "mypostgresdb"
    # inject db name into next steps
    ${next_steps}=    RW.NextSteps.Format    ${next_steps}
    ...    postgres_name=${db_name.stdout}
    RW.Core.Add Pre To Report    ${next_steps}


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
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
    ...    default=online-boutique
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster
    ...    default=sandbox-cluster-1
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
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${CLI_COMMAND}    ${CLI_COMMAND}
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}"}
    IF    "${RUN_LOCAL}" == "YES"
        ${kubectl}=    Evaluate    None
    END
    Set Suite Variable    ${kubectl}    ${kubectl}
