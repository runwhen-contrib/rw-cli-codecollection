*** Settings ***
Documentation       This taskset is used to suspend a flux resource for the purposes of executing chaos tasks. 
Metadata            Author    Shea Stewart
Metadata            Display Name    Kubernetes Flux Choas Testing
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             DateTime
Library             Collections
Library             String

Suite Setup         Suite Initialization


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
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    default=kubectl
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster
    ${RANDOMIZE}=    RW.Core.Import User Variable    RANDOMIZE
    ...    type=string
    ...    description=Boolean to determine whether to randomly select the impacted resource.   
    ...    enum=[Yes,No]
    ...    default=No
    ${FLUX_RESOURCE_TYPE}=    RW.Core.Import User Variable    FLUX_RESOURCE_TYPE
    ...    type=string
    ...    description=The type of the Flux resource to suspend.   
    ...    pattern=\w*
    ...    example=kustomization
    ...    default=kustomization
    ${FLUX_RESOURCE_NAME}=    RW.Core.Import User Variable    FLUX_RESOURCE_NAME
    ...    type=string
    ...    description=The name of the Flux resource to suspend.   
    ...    pattern=\w*
    ...    example=app-online-boutique
    ...    default=app-online-boutique
    ${FLUX_RESOURCE_NAMESPACE}=    RW.Core.Import User Variable    FLUX_RESOURCE_NAMESPACE
    ...    type=string
    ...    description=The name of the namespace that manages the Flux resource.   
    ...    pattern=\w*
    ...    example=flux-system
    ...    default=flux-system
    ${TARGET_NAMESPACE}=    RW.Core.Import User Variable    TARGET_NAMESPACE
    ...    type=string
    ...    description=The name of the namespace to target when invoking resource instability.   
    ...    pattern=\w*
    ...    example=online-boutique
    ...    default=online-boutique
    ${TARGET_RESOURCE}=    RW.Core.Import User Variable    TARGET_RESOURCE
    ...    type=string
    ...    description=The name of the target resource to run chaos commands in.   
    ...    pattern=\w*
    ...    example=deployment/cartservice
    ...    default=deployment/cartservice
    ${CHAOS_COMMAND}=    RW.Core.Import User Variable    CHAOS_COMMAND
    ...    type=string
    ...    description=The command to run in the target pod.  
    ...    pattern=\w*
    ...    example=/bin/sh -c "while true; do yes > /dev/null & done"
    ...    default=/bin/sh -c "while true; do yes > /dev/null & done"
    ${CHAOS_COMMAND_LOOP}=    RW.Core.Import User Variable    CHAOS_COMMAND_LOOP
    ...    type=string
    ...    description=The number of times to execute this command.  
    ...    pattern=\d*
    ...    example=2
    ...    default=1
    ${ADDNL_COMMAND}=    RW.Core.Import User Variable    ADDNL_COMMAND
    ...    type=string
    ...    description=Run any additional chaos command - verbatim.   
    ...    pattern=\w*
    ...    example=kubectl delete svc --all
    ...    default=kubectl get pods
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${FLUX_RESOURCE_TYPE}    ${FLUX_RESOURCE_TYPE}
    Set Suite Variable    ${FLUX_RESOURCE_NAME}    ${FLUX_RESOURCE_NAME}
    Set Suite Variable    ${FLUX_RESOURCE_NAMESPACE}    ${FLUX_RESOURCE_NAMESPACE}
    Set Suite Variable    ${TARGET_NAMESPACE}    ${TARGET_NAMESPACE}
    Set Suite Variable    ${TARGET_RESOURCE}    ${TARGET_RESOURCE}
    Set Suite Variable    ${CHAOS_COMMAND}    ${CHAOS_COMMAND}
    Set Suite Variable    ${CHAOS_COMMAND_LOOP}    ${CHAOS_COMMAND_LOOP}
    Set Suite Variable    ${ADDNL_COMMAND}    ${ADDNL_COMMAND}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}

*** Tasks ***
Suspend the Flux Resource Reconciliation
        [Documentation]    Suspends a flux resource so that it can be manipulated for chaos purposes. 
        [Tags]    Chaos    Flux    Kubernetes    Resource    Suspend
        ${suspend_flux_resource}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} patch ${FLUX_RESOURCE_TYPE} ${FLUX_RESOURCE_NAME} -n ${FLUX_RESOURCE_NAMESPACE} --type='json' -p='[{"op": "add", "path": "/spec/suspend", "value":true}]'
        ...    target_service=${kubectl}
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Commands Used:\n${history}

Find Random FluxCD Workload as Chaos Target
    [Documentation]    Inspects the Flux resource and randomly selects a deployment to tickle. Tehe. Only runs if RANDOMIZE = Yes. 
    [Tags]    Chaos    Flux    Kubernetes    Resource    Random
    IF     "${RANDOMIZE}" == "Yes"
        ${deployments}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployments -l kustomize.toolkit.fluxcd.io/name=${FLUX_RESOURCE_NAME} -n ${TARGET_NAMESPACE} -o json
        ...    target_service=${kubectl}
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        ${deployment_count}=    RW.CLI.Parse Cli Json Output
        ...    rsp=${deployments}
        ...    extract_path_to_var__deployments=items[]
        ...    from_var_with_path__deployments__to__length=length(@)
        ...    assign_stdout_from_var=length
        ${random_selection}=     Evaluate  random.sample(range(1, ${deployment_count.stdout}),1)   random
        ${selected_deployment}=    RW.CLI.Parse Cli Json Output
        ...    rsp=${deployments}
        ...    extract_path_to_var__selected_deployment=items${random_selection}.metadata.name
        ...    assign_stdout_from_var=selected_deployment
        ${deployment_name}=    Remove String    ${selected_deployment.stdout}    "

        RW.Core.Add Pre To Report    Selected Deployment:\n${deployment_name}
        Set Suite Variable    ${TARGET_RESOURCE}    deployment/${deployment_name}
    END

Execute Chaos Command
    [Documentation]    Run the desired chaos command within a targeted resource 
    [Tags]    Chaos    Flux    Kubernetes    Resource    Kill    OOM
    FOR    ${index}    IN RANGE    ${CHAOS_COMMAND_LOOP}
        ${run_chaos_command}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} exec ${TARGET_RESOURCE} -n ${TARGET_NAMESPACE} -- ${CHAOS_COMMAND}
        ...    target_service=${kubectl}
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Execute Additional Chaos Command
    [Documentation]    Run the additional command as input, verbatim. 
    [Tags]    Chaos    Flux    Kubernetes    Resource
    ${run_additional_command}=    RW.CLI.Run Cli
    ...    cmd=${ADDNL_COMMAND} -n ${TARGET_NAMESPACE} --context ${CONTEXT}
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Resume Flux Resource Reconciliation
    [Documentation]    Resumes Flux reconciliation on desired resource.  
    [Tags]    Chaos    Flux    Kubernetes    Resource    Resume
    ${resume_flux}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} patch ${FLUX_RESOURCE_TYPE} ${FLUX_RESOURCE_NAME} -n ${FLUX_RESOURCE_NAMESPACE} --type='json' -p='[{"op": "remove", "path": "/spec/suspend", "value":true}]'
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used:\n${history}