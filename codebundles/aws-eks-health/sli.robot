*** Settings ***
Documentation       Monitors the status of EKS / Fargate in the given AWS region.
Metadata            Author    jon-funk
Metadata            Display Name    AWS EKS Health Scan
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
Check EKS Fargate Cluster Health Status
    [Documentation]   This script checks the health status of an Amazon EKS cluster.
    [Tags]  EKS    Cluster Health    AWS    Kubernetes    Pods    Nodes  
    ${process}=    RW.CLI.Run Bash File    check_eks_cluster_health_status.sh
    ...    env=${env}
    ...    secret__AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
    ...    secret__AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
    IF    "Error" in """${process.stdout}"""
        RW.Core.Push Metric    0
    ELSE
        RW.Core.Push Metric    1
    END

*** Keywords ***
Suite Initialization
    ${AWS_REGION}=    RW.Core.Import User Variable    AWS_REGION
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

    Set Suite Variable    ${AWS_REGION}    ${AWS_REGION}
    Set Suite Variable    ${AWS_ACCESS_KEY_ID}    ${AWS_ACCESS_KEY_ID}
    Set Suite Variable    ${AWS_SECRET_ACCESS_KEY}    ${AWS_SECRET_ACCESS_KEY}

    Set Suite Variable
    ...    &{env}
    ...    AWS_REGION=${AWS_REGION}
