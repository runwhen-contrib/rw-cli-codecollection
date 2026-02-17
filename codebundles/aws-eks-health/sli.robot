*** Settings ***
Documentation       Monitors the health status of EKS clusters in the given AWS region.
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
Check Amazon EKS Cluster Health Status in AWS Region `${AWS_REGION}`
    [Documentation]    Checks the health status of EKS clusters and pushes a metric based on the result.
    [Tags]    EKS    Cluster Health    AWS    Kubernetes    Pods    Nodes    data:config
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=check_eks_cluster_health.sh
    ...    env=${env}
    ...    timeout_seconds=180

    IF    ${process.returncode} != 0
        RW.Core.Push Metric    0    sub_name=cluster_health
        RW.Core.Push Metric    0
        RETURN
    END

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat eks_cluster_health.json
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    ${issue_count}=    Evaluate    len($issue_list["issues"])
    IF    ${issue_count} > 0
        RW.Core.Push Metric    0    sub_name=cluster_health
        RW.Core.Push Metric    0
    ELSE
        RW.Core.Push Metric    1    sub_name=cluster_health
        RW.Core.Push Metric    1
    END

*** Keywords ***
Suite Initialization
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
