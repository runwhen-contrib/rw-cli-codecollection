*** Settings ***
Documentation       Checks the health status of EKS clusters, node groups, and Fargate profiles in the given AWS region.
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
Check EKS Cluster Health in AWS Region `${AWS_REGION}`
    [Documentation]    Checks overall EKS cluster health including status, configuration, add-ons, and node group summary.
    [Tags]    EKS    Cluster Health    AWS    Kubernetes    access:read-only    data:config
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=check_eks_cluster_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    IF    ${process.returncode} == -1
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=EKS cluster health check should complete within timeout in region `${AWS_REGION}`
        ...    actual=EKS cluster health check timed out for region `${AWS_REGION}`
        ...    title=EKS Cluster Health Check Timeout in Region `${AWS_REGION}`
        ...    reproduce_hint=${process.cmd}
        ...    details=Command timed out. This may indicate authentication issues, network problems, or AWS service delays.
        ...    next_steps=Check AWS credentials with 'aws sts get-caller-identity'\nVerify network connectivity to AWS APIs\nCheck if the IAM role has required EKS permissions
        RETURN
    END

    ${auth_failed}=    Run Keyword And Return Status    Should Contain    ${process.stdout}    AWS credentials not configured
    IF    ${auth_failed}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=AWS authentication should succeed for EKS health checks in region `${AWS_REGION}`
        ...    actual=AWS authentication failed for EKS health checks in region `${AWS_REGION}`
        ...    title=AWS Authentication Failed for EKS Health Check in Region `${AWS_REGION}`
        ...    reproduce_hint=${process.cmd}
        ...    details=${process.stdout}
        ...    next_steps=Verify AWS credentials are configured via the platform aws-auth block\nCheck that the aws_credentials secret is properly bound in the workspace\nTest authentication: aws sts get-caller-identity
        RETURN
    END

    RW.Core.Add Pre To Report    ${process.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat eks_cluster_health.json
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=EKS clusters in region `${AWS_REGION}` should be healthy with no issues
            ...    actual=EKS cluster health issues detected in region `${AWS_REGION}`
            ...    reproduce_hint=${process.cmd}
            ...    details=${item["details"]}
        END
    END

Check EKS Fargate Profile Health in AWS Region `${AWS_REGION}`
    [Documentation]    Checks the health status of all EKS Fargate profiles across clusters in the region.
    [Tags]    EKS    Fargate    Cluster Health    AWS    Kubernetes    Pods    access:read-only    data:config
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=check_eks_fargate_cluster_health_status.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    IF    ${process.returncode} == -1
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=EKS Fargate health check should complete within timeout in region `${AWS_REGION}`
        ...    actual=EKS Fargate health check timed out for region `${AWS_REGION}`
        ...    title=EKS Fargate Health Check Timeout in Region `${AWS_REGION}`
        ...    reproduce_hint=${process.cmd}
        ...    details=Command timed out. This may indicate authentication issues, network problems, or AWS service delays.
        ...    next_steps=Check AWS credentials with 'aws sts get-caller-identity'\nVerify network connectivity to AWS APIs
        RETURN
    END

    ${auth_failed}=    Run Keyword And Return Status    Should Contain    ${process.stdout}    AWS credentials not configured
    IF    ${auth_failed}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=AWS authentication should succeed for Fargate health checks in region `${AWS_REGION}`
        ...    actual=AWS authentication failed for Fargate health checks in region `${AWS_REGION}`
        ...    title=AWS Authentication Failed for Fargate Health Check in Region `${AWS_REGION}`
        ...    reproduce_hint=${process.cmd}
        ...    details=${process.stdout}
        ...    next_steps=Verify AWS credentials are configured via the platform aws-auth block\nCheck that the aws_credentials secret is properly bound in the workspace
        RETURN
    END

    RW.Core.Add Pre To Report    ${process.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat eks_fargate_health.json
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=EKS Fargate profiles in region `${AWS_REGION}` should be healthy
            ...    actual=EKS Fargate profile issues detected in region `${AWS_REGION}`
            ...    reproduce_hint=${process.cmd}
            ...    details=${item["details"]}
        END
    END

Check EKS Node Group Health in AWS Region `${AWS_REGION}`
    [Documentation]    Checks the health and scaling status of all managed EKS node groups across clusters in the region.
    [Tags]    AWS    EKS    Node Health    Kubernetes    Nodes    access:read-only    data:config
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=check_eks_nodegroup_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    IF    ${process.returncode} == -1
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=EKS node group health check should complete within timeout in region `${AWS_REGION}`
        ...    actual=EKS node group health check timed out for region `${AWS_REGION}`
        ...    title=EKS Node Group Health Check Timeout in Region `${AWS_REGION}`
        ...    reproduce_hint=${process.cmd}
        ...    details=Command timed out. This may indicate authentication issues, network problems, or AWS service delays.
        ...    next_steps=Check AWS credentials with 'aws sts get-caller-identity'\nVerify network connectivity to AWS APIs
        RETURN
    END

    ${auth_failed}=    Run Keyword And Return Status    Should Contain    ${process.stdout}    AWS credentials not configured
    IF    ${auth_failed}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=AWS authentication should succeed for node group health checks in region `${AWS_REGION}`
        ...    actual=AWS authentication failed for node group health checks in region `${AWS_REGION}`
        ...    title=AWS Authentication Failed for Node Group Health Check in Region `${AWS_REGION}`
        ...    reproduce_hint=${process.cmd}
        ...    details=${process.stdout}
        ...    next_steps=Verify AWS credentials are configured via the platform aws-auth block\nCheck that the aws_credentials secret is properly bound in the workspace
        RETURN
    END

    RW.Core.Add Pre To Report    ${process.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat eks_nodegroup_health.json
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=EKS node groups in region `${AWS_REGION}` should be healthy and properly scaled
            ...    actual=EKS node group issues detected in region `${AWS_REGION}`
            ...    reproduce_hint=${process.cmd}
            ...    details=${item["details"]}
        END
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
