*** Settings ***
Documentation       Monitors the status of EKS / Fargate in the given AWS region.
Metadata            Author    jon-funk
Metadata            Display Name    AWS EKS Fargate Health Scan
Metadata            Supports    AWS EKS Fargate
Metadata            Builder

Library             BuiltIn
Library             RW.Core
Library             RW.platform
Library             OperatingSystem
Library             String
Library             Process

Suite Setup         Suite Initialization

*** Tasks ***
Check EKS Fargate Cluster Health Status
    [Documentation]   This script checks the health status of an Amazon EKS Fargate cluster. It describes the Fargate profile, checks the status of all nodes and pods, and provides detailed information about each pod. The script requires the user to specify the cluster name, Fargate profile name, and AWS region.
    [Tags]  EKS    Fargate    Cluster Health    AWS    Kubernetes    Pods    Nodes  
    ${process}=    Run Process    ${CURDIR}/check_eks_fargate_cluster_health_status.sh    env=${env}
    IF    "Error" in """${process.stdout}"""
        RW.Core.Push Metric    0
    ELSE
        RW.Core.Push Metric    1
    END

*** Keywords ***
Suite Initialization
    ${AWS_REGION}=    RW.Core.Import Secret    AWS_REGION
    ...    type=string
    ...    description=AWS Region
    ...    pattern=\w*
    ${AWS_ACCESS_KEY_ID}=    RW.Core.Import Secret   AWS_ACCESS_KEY_ID
    ...    type=string
    ...    description=AWS Access Key ID
    ...    pattern=\w*
    ${AWS_SECRET_ACCESS_KEY}=    RW.Core.Import Secret   AWS_SECRET_ACCESS_KEY
    ...    type=string
    ...    description=AWS Secret Access Key
    ...    pattern=\w*

    Set Suite Variable    ${AWS_REGION}    ${AWS_REGION.value}
    Set Suite Variable    ${AWS_ACCESS_KEY_ID}    ${AWS_ACCESS_KEY_ID.value}
    Set Suite Variable    ${AWS_SECRET_ACCESS_KEY}    ${AWS_SECRET_ACCESS_KEY.value}

    Set Suite Variable
    ...    &{env}
    ...    AWS_REGION=${AWS_REGION}
    ...    AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
    ...    AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}