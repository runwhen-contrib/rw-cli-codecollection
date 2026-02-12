*** Settings ***
Documentation       Checks the health status of EKS and/or Fargate clusters in the given AWS region.
Metadata            Author    jon-funk
Metadata            Display Name    AWS EKS Cluster Health
Metadata            Supports    AWS,EKS,Fargate
Metadata            Builder

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             String
Library             Process

Suite Setup         Suite Initialization

*** Tasks ***
Check EKS Fargate Cluster Health Status in AWS Region `${AWS_REGION}`
    [Documentation]   This script checks the health status of an Amazon EKS Fargate cluster.
    [Tags]  EKS    Fargate    Cluster Health    AWS    Kubernetes    Pods    Nodes    access:read-only      data:config
    ${process}=    RW.CLI.Run Bash File    check_eks_fargate_cluster_health_status.sh
    ...    env=${env}
    IF    "Error" in """${process.stdout}"""
        RW.Core.Add Issue    title=EKS Fargate Cluster in ${AWS_REGION} is Unhealthy
        ...    severity=3
        ...    next_steps=Fetch the CloudWatch logs of available EKS clusters in ${AWS_REGION}.
        ...    expected=The EKS Fargate cluster is healthy.
        ...    actual=The EKS Fargate cluster is unhealthy.
        ...    reproduce_hint=Run the script check_eks_fargate_cluster_health_status.sh
        ...    details=${process.stdout}
    END
    RW.Core.Add Pre To Report    ${process.stdout}

Check Amazon EKS Cluster Health Status in AWS Region `${AWS_REGION}`
    [Documentation]   This script checks the health status of an Amazon EKS cluster. 
    [Tags]  EKS       Cluster Health    AWS    Kubernetes    Pods    Nodes    access:read-only    data:config
    ${process}=    RW.CLI.Run Bash File    check_eks_cluster_health.sh
    ...    env=${env}
    IF    "Error" in """${process.stdout}"""
        RW.Core.Add Issue    title=EKS Cluster in ${AWS_REGION} is Unhealthy
        ...    severity=3
        ...    next_steps=Fetch the CloudWatch logs of available EKS clusters in ${AWS_REGION}.  
        ...    expected=The EKS cluster is healthy.
        ...    actual=The EKS cluster is unhealthy.
        ...    reproduce_hint=Run the script check_eks_cluster_health.sh
        ...    details=${process.stdout}
    END
    RW.Core.Add Pre To Report    ${process.stdout}

Monitor EKS Cluster Health in AWS Region `${AWS_REGION}`
    [Documentation]   This bash script is designed to monitor the health and status of an Amazon EKS cluster.
    [Tags]  AWS    EKS    Fargate    Bash Script    Node Health    access:read-only    data:config
    ${process}=    RW.CLI.Run Bash File    list_eks_fargate_metrics.sh
    ...    env=${env}
    RW.Core.Add Pre To Report    ${process.stdout}


*** Keywords ***
Suite Initialization
    # AWS credentials are provided by the platform from the aws-auth block (runwhen-local);
    # the runtime uses aws_utils to set up the auth environment (IRSA, access key, assume role, etc.).
    ${AWS_REGION}=    RW.Core.Import User Variable    AWS_REGION
    ...    type=string
    ...    description=AWS Region
    ...    pattern=\w*
    ${aws_credentials}=    RW.Core.Import Secret    aws_credentials
    ...    type=string
    ...    description=AWS credentials from the workspace (from aws-auth block; e.g. aws:access_key@cli, aws:irsa@cli).
    ...    pattern=\w*

    Set Suite Variable    ${AWS_REGION}    ${AWS_REGION}
    Set Suite Variable    ${aws_credentials}    ${aws_credentials}

    Set Suite Variable
    ...    &{env}
    ...    AWS_REGION=${AWS_REGION}