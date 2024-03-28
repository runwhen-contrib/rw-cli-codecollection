*** Settings ***
Documentation       
Metadata            Author    Placeholder
Metadata            Display Name    eks-fargate-cluster-health-issue
Metadata            Supports    `AWS`, `EKS Fargate`, `Cluster Health`, `Potential Issue`, `Developer Report`, `Investigation Required`, `Cloud Services`, `Incident Triage`, 
Metadata            Builder

Library             BuiltIn
Library             RW.Core
Library             RW.platform
Library             OperatingSystem
Library             String
Library             Process

Suite Setup         Suite Initialization

*** Tasks ***
Check EKS Fargate Cluster Health Status using aws CLI
    [Documentation]   This script checks the health status of an Amazon EKS Fargate cluster. It describes the Fargate profile, checks the status of all nodes and pods, and provides detailed information about each pod. The script requires the user to specify the cluster name, Fargate profile name, and AWS region.
    [Tags]  EKS    Fargate    Cluster Health    AWS    Kubernetes    Pods    Nodes    Shell Script    
    ${process}=    Run Process    ${CURDIR}/check_eks_fargate_cluster_health_status.sh    env=${env}
    RW.Core.Add Pre To Report    ${process.stdout}

Examine AWS VPC CNI plugin for EKS Fargate Networking Issues
    [Documentation]   This bash script is designed to monitor the health and status of an Amazon EKS cluster. It fetches information about the Fargate profile, checks the health status of EKS nodes, verifies the status of all pods in all namespaces, and checks the CNI version. The script is intended to be run in an environment where AWS CLI and kubectl are installed and configured.
    [Tags]  AWS    EKS    Fargate    Bash Script    Node Health    Pod Status    CNI Version    Kubernetes    
    ${process}=    Run Process    ${CURDIR}/examine_aws_vpc_cni_eks_fargate_networking_issues.sh    env=${env}
    RW.Core.Add Pre To Report    ${process.stdout}


*** Keywords ***
Suite Initialization

    ${CLUSTER_NAME}=    RW.Core.Import User Variable    CLUSTER_NAME
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder

    ${FARGATE_PROFILE}=    RW.Core.Import User Variable    FARGATE_PROFILE
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder

    ${REGION}=    RW.Core.Import User Variable    REGION
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder

    ${AWS_REGION}=    RW.Core.Import User Variable    AWS_REGION
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder

    ${EKS_CLUSTER_NAME}=    RW.Core.Import User Variable    EKS_CLUSTER_NAME
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder

    ${FARGATE_PROFILE_NAME}=    RW.Core.Import User Variable    FARGATE_PROFILE_NAME
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder

    ${PROFILE}=    RW.Core.Import User Variable    PROFILE
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder

    ${LOG_GROUP_NAME}=    RW.Core.Import User Variable    LOG_GROUP_NAME
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder

    ${START_TIME}=    RW.Core.Import User Variable    START_TIME
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder

    ${END_TIME}=    RW.Core.Import User Variable    END_TIME
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder

    ${FILTER_PATTERN}=    RW.Core.Import User Variable    FILTER_PATTERN
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder


    Set Suite Variable    ${CLUSTER_NAME}    ${CLUSTER_NAME}
    Set Suite Variable    ${FARGATE_PROFILE}    ${FARGATE_PROFILE}
    Set Suite Variable    ${REGION}    ${REGION}
    Set Suite Variable    ${AWS_REGION}    ${AWS_REGION}
    Set Suite Variable    ${EKS_CLUSTER_NAME}    ${EKS_CLUSTER_NAME}
    Set Suite Variable    ${FARGATE_PROFILE_NAME}    ${FARGATE_PROFILE_NAME}
    Set Suite Variable    ${PROFILE}    ${PROFILE}
    Set Suite Variable    ${LOG_GROUP_NAME}    ${LOG_GROUP_NAME}
    Set Suite Variable    ${START_TIME}    ${START_TIME}
    Set Suite Variable    ${END_TIME}    ${END_TIME}
    Set Suite Variable    ${FILTER_PATTERN}    ${FILTER_PATTERN}

    Set Suite Variable
    ...    &{env}
    ...    CLUSTER_NAME=${CLUSTER_NAME}
    ...    FARGATE_PROFILE=${FARGATE_PROFILE}
    ...    REGION=${REGION}
    ...    AWS_REGION=${AWS_REGION}
    ...    EKS_CLUSTER_NAME=${EKS_CLUSTER_NAME}
    ...    FARGATE_PROFILE_NAME=${FARGATE_PROFILE_NAME}
    ...    PROFILE=${PROFILE}
    ...    LOG_GROUP_NAME=${LOG_GROUP_NAME}
    ...    START_TIME=${START_TIME}
    ...    END_TIME=${END_TIME}
    ...    FILTER_PATTERN=${FILTER_PATTERN}