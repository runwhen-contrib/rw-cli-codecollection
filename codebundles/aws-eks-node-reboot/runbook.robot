*** Settings ***
Documentation       Queries a node group within a EKS cluster to check if the nodegroup has degraded service, indicating ongoing reboots or other issues.
Metadata            Author    jon-funk
Metadata            Display Name    AWS EKS Nodegroup Status Check
Metadata            Supports    AWS,EKS

Library             RW.Core
Library             RW.CLI

Suite Setup         Suite Initialization


*** Tasks ***
Check EKS Nodegroup Status in `${EKS_CLUSTER_NAME}`
    [Documentation]    Performs a check on a given cluster's nodegroup, raising an issue if the status of the nodegroup is not healthy.
    [Tags]    aws    eks    node    group    status    access:read-only    data:config
    # AWS credentials are provided by the platform from the aws-auth block (runwhen-local).
    ${node_state}=    RW.CLI.Run Cli
    ...    cmd=aws eks describe-nodegroup --cluster-name ${EKS_CLUSTER_NAME} --nodegroup-name ${EKS_NODEGROUP} --output json
    ...    target_service=${AWS_SERVICE}
    # Parse nodegroup status and check if it's active
    ${nodegroup_status}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${node_state}
    ...    extract_path_to_var__status=nodegroup.status
    
    ${status_value}=    Set Variable    ${nodegroup_status.stdout}
    IF    '${status_value}' != 'ACTIVE'
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=EKS nodegroup should be in ACTIVE state
        ...    actual=EKS nodegroup status: ${status_value}
        ...    title=EKS Cluster `${EKS_CLUSTER_NAME}` Has Unhealthy Nodegroup `${EKS_NODEGROUP}`
        ...    details=EKS cluster `${EKS_CLUSTER_NAME}` nodegroup `${EKS_NODEGROUP}` in unhealthy state: "${node_state.stdout}"
        ...    reproduce_hint=Check EKS nodegroup status and health in AWS console
        ...    next_steps=Check nodegroup events in AWS console, verify node health, and consider nodegroup replacement if needed
    END
    RW.Core.Add Pre To Report    Current Nodegroup State:\n\n
    RW.Core.Add Pre To Report    ${node_state.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}


*** Keywords ***
Suite Initialization
    # AWS credentials are provided by the platform from the aws-auth block (runwhen-local);
    # the runtime uses aws_utils to set up the auth environment (IRSA, access key, assume role, etc.).
    ${aws_credentials}=    RW.Core.Import Secret    aws_credentials
    ...    type=string
    ...    description=AWS credentials from the workspace (from aws-auth block; e.g. aws:access_key@cli, aws:irsa@cli).
    ...    pattern=\w*
    ${AWS_SERVICE}=    RW.Core.Import Service    aws
    ...    type=string
    ...    description=The selected RunWhen Service to use for accessing services within a network.
    ...    pattern=\w*
    ...    example=aws-service.shared
    ...    default=aws-service.shared
    ${AWS_DEFAULT_REGION}=    RW.Core.Import User Variable    AWS_DEFAULT_REGION
    ...    type=string
    ...    description=The AWS region to scope API requests to.
    ...    pattern=\w*
    ...    example=us-west-1
    ...    default=us-west-1
    ${EKS_CLUSTER_NAME}=    RW.Core.Import User Variable    EKS_CLUSTER_NAME
    ...    type=string
    ...    description=The name of the AWS EKS cluster to query.
    ...    pattern=\w*
    ...    example=my-eks-cluster
    ${EKS_NODEGROUP}=    RW.Core.Import User Variable    EKS_NODEGROUP
    ...    type=string
    ...    description=The name of the AWS EKS Nodegroup running the EKS workloads.
    ...    pattern=\w*
    ...    example=my-eks-nodegroup
    Set Suite Variable    ${aws_credentials}    ${aws_credentials}
    Set Suite Variable    ${AWS_DEFAULT_REGION}    ${AWS_DEFAULT_REGION}
    Set Suite Variable    ${AWS_SERVICE}    ${AWS_SERVICE}
    Set Suite Variable    ${EKS_CLUSTER_NAME}    ${EKS_CLUSTER_NAME}
    Set Suite Variable    ${EKS_NODEGROUP}    ${EKS_NODEGROUP}
