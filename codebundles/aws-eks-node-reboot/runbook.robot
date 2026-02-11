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
    ${node_state}=    RW.CLI.Run Cli
    ...    cmd=${AWS_ASSUME_ROLE_CMD} aws eks describe-nodegroup --cluster-name ${EKS_CLUSTER_NAME} --nodegroup-name ${EKS_NODEGROUP} --output json
    ...    target_service=${AWS_SERVICE}
    ...    secret__aws_access_key_id=${aws_access_key_id}
    ...    secret__aws_secret_access_key=${aws_secret_access_key}
    ...    secret__aws_role_arn=${aws_role_arn}
    ...    secret__aws_assume_role_name=${aws_assume_role_name}
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
    ${AWS_SERVICE}=    RW.Core.Import Service    aws
    ...    type=string
    ...    description=The selected RunWhen Service to use for accessing services within a network.
    ...    pattern=\w*
    ...    example=aws-service.shared
    ...    default=aws-service.shared
    ${aws_access_key_id}=    RW.Core.Import Secret    aws_access_key_id
    ...    type=string
    ...    description=The AWS access key ID to use for connecting to AWS APIs.
    ...    pattern=\w*
    ...    example=SUPERSECRETKEYID
    ${aws_secret_access_key}=    RW.Core.Import Secret    aws_secret_access_key
    ...    type=string
    ...    description=The AWS access key to use for connecting to AWS APIs.
    ...    pattern=\w*
    ...    example=SUPERSECRETKEY
    ${aws_role_arn}=    RW.Core.Import Secret    aws_role_arn
    ...    type=string
    ...    description=The AWS role ARN to use for connecting to AWS APIs.
    ...    pattern=\w*
    ...    example=arn:aws:iam::ACCOUNT_ID:role/ROLE_NAME
    ${aws_assume_role_name}=    RW.Core.Import Secret    aws_assume_role_name
    ...    type=string
    ...    description=The AWS role ARN to use for connecting to AWS APIs.
    ...    pattern=\w*
    ...    example=runwhen-sa
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
    Set Suite Variable    ${aws_access_key_id}    ${aws_access_key_id}
    Set Suite Variable    ${aws_secret_access_key}    ${aws_secret_access_key}
    Set Suite Variable    ${aws_role_arn}    ${aws_role_arn}
    Set Suite Variable    ${aws_assume_role_name}    ${aws_assume_role_name}
    Set Suite Variable    ${AWS_DEFAULT_REGION}    ${AWS_DEFAULT_REGION}
    Set Suite Variable    ${AWS_SERVICE}    ${AWS_SERVICE}
    Set Suite Variable    ${EKS_CLUSTER_NAME}    ${EKS_CLUSTER_NAME}
    Set Suite Variable    ${EKS_NODEGROUP}    ${EKS_NODEGROUP}
    Set Suite Variable
    ...    ${AWS_ASSUME_ROLE_CMD}
    ...    role_json=$(AWS_ACCESS_KEY_ID=$${aws_access_key_id.key} AWS_SECRET_ACCESS_KEY=$${aws_secret_access_key.key} AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION} aws sts assume-role --role-arn $${aws_role_arn.key} --role-session-name $${aws_assume_role_name.key}) && AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION} AWS_ACCESS_KEY_ID=$(echo $role_json | jq -r '.Credentials.AccessKeyId') AWS_SECRET_ACCESS_KEY=$(echo $role_json | jq -r '.Credentials.SecretAccessKey') AWS_SESSION_TOKEN=$(echo $role_json | jq -r '.Credentials.SessionToken')

