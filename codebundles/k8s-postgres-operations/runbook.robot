*** Settings ***
Documentation       PostgreSQL Operations Runbook for Kubernetes clusters
...                 Supports CrunchyDB and Zalando PostgreSQL operators
...                 Primary focus on reinitializing failed cluster members
Metadata            Author    stewartshea
Metadata            Display Name    PostgreSQL Operations
Metadata            Supports    Kubernetes,PostgreSQL,CrunchyDB,Zalando

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization
Suite Teardown      Suite Teardown

*** Tasks ***
Reinitialize Failed PostgreSQL Cluster Members for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Identify and reinitialize any failed cluster members
    [Tags]    access:read-write    reinitialize    recovery    postgres    operations
    ${reinit_result}=    RW.CLI.Run Bash File
    ...    bash_file=reinitialize_cluster_member.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=600
    RW.Core.Add Pre To Report    ${reinit_result.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}
    
    # Check if reinitialize operation had errors
    ${reinit_failed}=    Run Keyword And Return Status
    ...    Should Contain    ${reinit_result.stdout}    "severity": "error"
    
    IF    ${reinit_failed}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Failed cluster members should be successfully reinitialized
        ...    actual=Errors occurred during cluster member reinitialize operation
        ...    title=PostgreSQL Cluster Member Reinitialize Failed
        ...    reproduce_hint=Check patronictl status: kubectl exec <pod> -c database -- patronictl list
        ...    details=Review the reinitialize report for specific error details and manual intervention steps.
    ELSE
        # Check if any members were actually reinitialized
        ${members_reinitialized}=    Run Keyword And Return Status
        ...    Should Contain    ${reinit_result.stdout}    successfully reinitialized
        
        IF    ${members_reinitialized}
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=All cluster members should be healthy
            ...    actual=Some cluster members required reinitialize operation
            ...    title=PostgreSQL Cluster Members Were Reinitialized
            ...    reproduce_hint=Monitor cluster: kubectl exec <pod> -c database -- patronictl list
            ...    details=Cluster members have been reinitialized. Monitor for stability.
        END
    END

Perform PostgreSQL Cluster Failover Operation for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Execute failover operation to promote a specific replica or perform automatic failover
    [Tags]    access:read-write    failover    postgres    operations    emergency
    ${failover_result}=    RW.CLI.Run Bash File
    ...    bash_file=cluster_operations.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=300
    ...    cmd_override=OPERATION=failover bash cluster_operations.sh
    RW.Core.Add Pre To Report    ${failover_result.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}
    
    # Check if failover was successful
    ${failover_failed}=    Run Keyword And Return Status
    ...    Should Contain    ${failover_result.stdout}    "severity": "error"
    
    IF    ${failover_failed}
        RW.Core.Add Issue
        ...    severity=1
        ...    expected=PostgreSQL cluster failover should complete successfully
        ...    actual=Errors occurred during failover operation for cluster ${OBJECT_NAME}
        ...    title=PostgreSQL Cluster Failover Failed
        ...    reproduce_hint=Check cluster status: kubectl exec <pod> -c ${DATABASE_CONTAINER} -- patronictl list
        ...    details=Review the failover operation logs for specific error details and manual intervention steps.
    ELSE
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=PostgreSQL cluster failover completed
        ...    actual=PostgreSQL cluster ${OBJECT_NAME} failover operation completed successfully
        ...    title=PostgreSQL Cluster Failover Completed
        ...    reproduce_hint=Monitor cluster: kubectl exec <pod> -c ${DATABASE_CONTAINER} -- patronictl list
        ...    details=Failover operation completed. Verify new master is functioning correctly.
    END



Restart PostgreSQL Cluster with Rolling Update for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Perform rolling restart of all PostgreSQL cluster members
    [Tags]    access:read-write    restart    postgres    operations    maintenance
    ${restart_result}=    RW.CLI.Run Bash File
    ...    bash_file=cluster_operations.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=900
    ...    cmd_override=OPERATION=restart bash cluster_operations.sh
    RW.Core.Add Pre To Report    ${restart_result.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}
    
    # Check if restart was successful
    ${restart_failed}=    Run Keyword And Return Status
    ...    Should Contain    ${restart_result.stdout}    "severity": "error"
    
    IF    ${restart_failed}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=PostgreSQL cluster rolling restart should complete successfully
        ...    actual=Errors occurred during rolling restart for cluster ${OBJECT_NAME}
        ...    title=PostgreSQL Cluster Rolling Restart Failed
        ...    reproduce_hint=Check pod status: kubectl get pods -n ${NAMESPACE} -l ${RESOURCE_LABELS}
        ...    details=Review restart logs and check for pod startup issues or resource constraints.
    ELSE
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=PostgreSQL cluster rolling restart completed
        ...    actual=PostgreSQL cluster ${OBJECT_NAME} rolling restart completed successfully
        ...    title=PostgreSQL Cluster Rolling Restart Completed
        ...    reproduce_hint=Verify cluster: kubectl exec <pod> -c ${DATABASE_CONTAINER} -- patronictl list
        ...    details=Rolling restart completed. All cluster members should be running with updated configuration.
    END

Verify Cluster Recovery and Generate Summary for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Final verification of cluster health after operations
    [Tags]    access:read-write    verification    summary    postgres
    ${final_check}=    RW.CLI.Run Bash File
    ...    bash_file=cluster_operations.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    RW.Core.Add Pre To Report    ${final_check.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}
    
    # Generate summary based on all operations
    ${all_healthy}=    Run Keyword And Return Status
    ...    Should Not Contain Any    ${final_check.stdout}    "severity": "error"    "severity": "critical"
    
    IF    ${all_healthy}
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=PostgreSQL cluster operations completed
        ...    actual=PostgreSQL cluster ${OBJECT_NAME} is now healthy
        ...    title=PostgreSQL Cluster Operations Completed Successfully
        ...    reproduce_hint=Monitor ongoing: kubectl get pods -n ${NAMESPACE}
        ...    details=All PostgreSQL operations completed successfully. Cluster is healthy.
    ELSE
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=PostgreSQL cluster should be fully operational after recovery operations
        ...    actual=Some issues remain in PostgreSQL cluster after operations
        ...    title=PostgreSQL Cluster Still Has Issues
        ...    reproduce_hint=Review logs: kubectl logs <pod> -c database -n ${NAMESPACE}
        ...    details=Manual intervention may be required to fully resolve cluster issues.
    END

*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=The name of the Kubernetes namespace to scope actions and searching to.
    ...    pattern=\w*
    ...    example=my-namespace
    ${OBJECT_NAME}=    RW.Core.Import User Variable    OBJECT_NAME
    ...    type=string
    ...    description=The name of the PostgreSQL cluster object.
    ...    pattern=\w*
    ...    example=my-postgres-cluster
    ${OBJECT_API_VERSION}=    RW.Core.Import User Variable    OBJECT_API_VERSION
    ...    type=string
    ...    description=The API version of the PostgreSQL cluster object.
    ...    pattern=.*
    ...    example=postgres-operator.crunchydata.com/v1beta1
    ${DATABASE_CONTAINER}=    RW.Core.Import User Variable    DATABASE_CONTAINER
    ...    type=string
    ...    description=The name of the database container in the PostgreSQL pods.
    ...    enum=[database,postgres]
    ...    example=database
    ...    default=database


    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}","KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}","CONTEXT":"${CONTEXT}","NAMESPACE":"${NAMESPACE}","OBJECT_NAME":"${OBJECT_NAME}","OBJECT_API_VERSION":"${OBJECT_API_VERSION}","DATABASE_CONTAINER":"${DATABASE_CONTAINER}"}

Suite Teardown
    RW.Core.Upload File    cluster_operations_report.out
    RW.Core.Upload File    reinitialize_report.out
