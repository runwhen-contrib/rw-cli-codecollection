*** Settings ***
Documentation       Checks the health status of an EKS cluster including node groups, add-ons, and Fargate profiles.
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
Check EKS Cluster `${EKS_CLUSTER_NAME}` Health in AWS Region `${AWS_REGION}`
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
        ...    expected=EKS cluster health check should complete within timeout for `${EKS_CLUSTER_NAME}` in `${AWS_REGION}`
        ...    actual=EKS cluster health check timed out for `${EKS_CLUSTER_NAME}` in `${AWS_REGION}`
        ...    title=EKS Cluster Health Check Timeout for `${EKS_CLUSTER_NAME}` in `${AWS_REGION}`
        ...    reproduce_hint=${process.cmd}
        ...    details=Command timed out. This may indicate authentication issues, network problems, or AWS service delays.
        ...    next_steps=Check AWS credentials with 'aws sts get-caller-identity'\nVerify network connectivity to AWS APIs\nCheck if the IAM role has required EKS permissions
        RETURN
    END

    ${auth_failed_1}=    Run Keyword And Return Status    Should Contain    ${process.stdout}    AWS credentials not configured
    ${auth_failed_2}=    Run Keyword And Return Status    Should Contain    ${process.stdout}    get-caller-identity failed
    IF    ${auth_failed_1} or ${auth_failed_2}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=AWS authentication should succeed for EKS cluster `${EKS_CLUSTER_NAME}` in `${AWS_REGION}`
        ...    actual=AWS authentication failed for EKS cluster `${EKS_CLUSTER_NAME}` in `${AWS_REGION}`
        ...    title=AWS Authentication Failed for EKS Cluster `${EKS_CLUSTER_NAME}` in `${AWS_REGION}`
        ...    reproduce_hint=${process.cmd}
        ...    details=${process.stdout}
        ...    next_steps=Verify AWS credentials are configured via the platform aws-auth block\nCheck that the aws_credentials secret is properly bound in the workspace\nTest authentication: aws sts get-caller-identity
        RETURN
    END

    RW.Core.Add Pre To Report    ${process.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat eks_cluster_health.json 2>/dev/null || echo '{"issues": []}'
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
            ...    expected=EKS cluster `${EKS_CLUSTER_NAME}` in `${AWS_REGION}` should be healthy with no issues
            ...    actual=EKS cluster `${EKS_CLUSTER_NAME}` in `${AWS_REGION}` has health issues
            ...    reproduce_hint=${process.cmd}
            ...    details=${item["details"]}
        END
    END

Check Fargate Profile Health for EKS Cluster `${EKS_CLUSTER_NAME}` in AWS Region `${AWS_REGION}`
    [Documentation]    Checks the health status of all Fargate profiles for the EKS cluster.
    [Tags]    EKS    Fargate    Cluster Health    AWS    Kubernetes    Pods    access:read-only    data:config
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=check_eks_fargate_cluster_health_status.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    IF    ${process.returncode} == -1
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Fargate health check should complete within timeout for EKS cluster `${EKS_CLUSTER_NAME}` in `${AWS_REGION}`
        ...    actual=Fargate health check timed out for EKS cluster `${EKS_CLUSTER_NAME}` in `${AWS_REGION}`
        ...    title=Fargate Health Check Timeout for EKS Cluster `${EKS_CLUSTER_NAME}` in `${AWS_REGION}`
        ...    reproduce_hint=${process.cmd}
        ...    details=Command timed out. This may indicate authentication issues, network problems, or AWS service delays.
        ...    next_steps=Check AWS credentials with 'aws sts get-caller-identity'\nVerify network connectivity to AWS APIs
        RETURN
    END

    ${auth_failed_1}=    Run Keyword And Return Status    Should Contain    ${process.stdout}    AWS credentials not configured
    ${auth_failed_2}=    Run Keyword And Return Status    Should Contain    ${process.stdout}    get-caller-identity failed
    IF    ${auth_failed_1} or ${auth_failed_2}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=AWS authentication should succeed for EKS cluster `${EKS_CLUSTER_NAME}` in `${AWS_REGION}`
        ...    actual=AWS authentication failed for EKS cluster `${EKS_CLUSTER_NAME}` in `${AWS_REGION}`
        ...    title=AWS Authentication Failed for Fargate Check on EKS Cluster `${EKS_CLUSTER_NAME}` in `${AWS_REGION}`
        ...    reproduce_hint=${process.cmd}
        ...    details=${process.stdout}
        ...    next_steps=Verify AWS credentials are configured via the platform aws-auth block\nCheck that the aws_credentials secret is properly bound in the workspace
        RETURN
    END

    RW.Core.Add Pre To Report    ${process.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat eks_fargate_health.json 2>/dev/null || echo '{"issues": []}'
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
            ...    expected=Fargate profiles for EKS cluster `${EKS_CLUSTER_NAME}` in `${AWS_REGION}` should be healthy
            ...    actual=Fargate profile issues detected for EKS cluster `${EKS_CLUSTER_NAME}` in `${AWS_REGION}`
            ...    reproduce_hint=${process.cmd}
            ...    details=${item["details"]}
        END
    END

Check Node Group Health for EKS Cluster `${EKS_CLUSTER_NAME}` in AWS Region `${AWS_REGION}`
    [Documentation]    Checks the health and scaling status of all managed node groups for the EKS cluster.
    [Tags]    AWS    EKS    Node Health    Kubernetes    Nodes    access:read-only    data:config
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=check_eks_nodegroup_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    IF    ${process.returncode} == -1
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Node group health check should complete within timeout for EKS cluster `${EKS_CLUSTER_NAME}` in `${AWS_REGION}`
        ...    actual=Node group health check timed out for EKS cluster `${EKS_CLUSTER_NAME}` in `${AWS_REGION}`
        ...    title=Node Group Health Check Timeout for EKS Cluster `${EKS_CLUSTER_NAME}` in `${AWS_REGION}`
        ...    reproduce_hint=${process.cmd}
        ...    details=Command timed out. This may indicate authentication issues, network problems, or AWS service delays.
        ...    next_steps=Check AWS credentials with 'aws sts get-caller-identity'\nVerify network connectivity to AWS APIs
        RETURN
    END

    ${auth_failed_1}=    Run Keyword And Return Status    Should Contain    ${process.stdout}    AWS credentials not configured
    ${auth_failed_2}=    Run Keyword And Return Status    Should Contain    ${process.stdout}    get-caller-identity failed
    IF    ${auth_failed_1} or ${auth_failed_2}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=AWS authentication should succeed for EKS cluster `${EKS_CLUSTER_NAME}` in `${AWS_REGION}`
        ...    actual=AWS authentication failed for EKS cluster `${EKS_CLUSTER_NAME}` in `${AWS_REGION}`
        ...    title=AWS Authentication Failed for Node Group Check on EKS Cluster `${EKS_CLUSTER_NAME}` in `${AWS_REGION}`
        ...    reproduce_hint=${process.cmd}
        ...    details=${process.stdout}
        ...    next_steps=Verify AWS credentials are configured via the platform aws-auth block\nCheck that the aws_credentials secret is properly bound in the workspace
        RETURN
    END

    RW.Core.Add Pre To Report    ${process.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat eks_nodegroup_health.json 2>/dev/null || echo '{"issues": []}'
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
            ...    expected=Node groups for EKS cluster `${EKS_CLUSTER_NAME}` in `${AWS_REGION}` should be healthy and properly scaled
            ...    actual=Node group issues detected for EKS cluster `${EKS_CLUSTER_NAME}` in `${AWS_REGION}`
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
    ${EKS_CLUSTER_NAME}=    RW.Core.Import User Variable    EKS_CLUSTER_NAME
    ...    type=string
    ...    description=The name of the EKS cluster to check.
    ...    pattern=\w*
    ${aws_credentials}=    RW.Core.Import Secret    aws_credentials
    ...    type=string
    ...    description=AWS credentials from the workspace (from aws-auth block; e.g. aws:access_key@cli, aws:irsa@cli).
    ...    pattern=\w*
    Set Suite Variable    ${AWS_REGION}    ${AWS_REGION}
    Set Suite Variable    ${EKS_CLUSTER_NAME}    ${EKS_CLUSTER_NAME}
    Set Suite Variable    ${aws_credentials}    ${aws_credentials}
    Set Suite Variable
    ...    &{env}
    ...    AWS_REGION=${AWS_REGION}
    ...    EKS_CLUSTER_NAME=${EKS_CLUSTER_NAME}
