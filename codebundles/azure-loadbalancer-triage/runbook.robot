*** Settings ***
Documentation       Triages issues related to a Azure Loadbalancers, Kubernetes ingress objects and services.
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes Ingress Healthcheck
Metadata            Supports    Kubernetes,AKS,Azure

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Health Check Azure Load Balancer
    [Documentation]    Queries a Azure Loadbalancer's health probe to determine if it's in a healthy state.
    [Tags]    load    balancer    azure
    ${lb_id}=    RW.CLI.Run Cli
    ...    cmd=az login --service-principal -u $${AZ_USERNAME.key} -p $${AZ_CLIENT_SECRET.key} --tenant $${AZ_TENANT.key} > /dev/null 2>&1 && az network lb list --query "[?name=='${AZ_LB_NAME}']" | jq -r '.[0].id'
    ...    secret__az_username=${AZ_USERNAME}
    ...    secret__az_client_secret=${AZ_CLIENT_SECRET}
    ...    secret__az_tenant=${AZ_TENANT}
    ${activity_logs}=    RW.CLI.Run Cli
    ...    cmd=START_TIME=$(date -d "${AZ_HISTORY_RANGE} hours ago" '+%Y-%m-%dT%H:%M:%SZ') && END_TIME=$(date '+%Y-%m-%dT%H:%M:%SZ') && az login --service-principal -u $${AZ_USERNAME.key} -p $${AZ_CLIENT_SECRET.key} --tenant $${AZ_TENANT.key} > /dev/null 2>&1 && az monitor activity-log list --start-time $START_TIME --end-time $END_TIME --query "[?resourceType.value=='MICROSOFT.NETWORK/loadbalancers' && resourceId=='${lb_id.stdout}']" | jq -r '.[] | [(.eventTimestamp // "N/A"), (.status.localizedValue // "N/A"), (.subStatus.localizedValue // "N/A"), (.properties.details // "N/A")] | @tsv' | while IFS=$'\t' read -r timestamp status substatus details; do printf "%-30s | %-30s | %-60s | %s\n" "$timestamp" "$status" "$substatus" "$details"; done
    ...    secret__az_username=${AZ_USERNAME}
    ...    secret__az_client_secret=${AZ_CLIENT_SECRET}
    ...    secret__az_tenant=${AZ_TENANT}
    ${activity_logs_report}=    Set Variable    "Azure Load Balancer Health Report:"
    IF    """${activity_logs.stdout}""" == ""
        ${activity_logs_report}=    Set Variable
        ...    "${activity_logs_report}\n\nNo activity log events could be pulled for this resource. If there are events, consider checking the configured time range."
    ELSE
        ${activity_logs_report}=    Set Variable    "${activity_logs_report}\n\n${activity_logs.stdout}"
    END
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${activity_logs}
    ...    set_severity_level=2
    ...    set_issue_expected=No activity logs indicating failures for the resource.
    ...    set_issue_actual=Found activity logs indicating the resource has recently experienced an error.
    ...    set_issue_title=Load Balancer Activity Log Indicates Recent Errors
    ...    set_issue_details=Activity Log History\n\n${activity_logs.stdout}
    ...    set_issue_next_steps=Run 'az aks get-credentials' and with the credentials/context provided, use `kubectl describe service -l service.beta.kubernetes.io/azure-load-balancer-internal=true' to get a list of services and inspect their selectors. If the selectors are correct, begin troubleshooting the resource the selectors point to.
    ...    _line__raise_issue_if_contains=Error
    ...    _line__raise_issue_if_contains=Critical
    ...    _line__raise_issue_if_contains=In Progress
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${activity_logs_report}
    RW.Core.Add Pre To Report    Commands Used: ${history}


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${kubectl}=    RW.Core.Import Service    kubectl
    ...    description=The location service used to interpret shell commands.
    ...    default=kubectl-service.shared
    ...    example=kubectl-service.shared
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=The name of the Kubernetes namespace to scope actions and searching to.
    ...    pattern=\w*
    ...    example=my-namespace
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    ${SKIP_K8S}=    RW.Core.Import User Variable
    ...    SKIP_K8S
    ...    type=string
    ...    description=Skip the Kubernetes Ingress Object health check. This may be desirable if the Kubernetes API of your cluster is not public.
    ...    enum=[yes,no]
    ...    example=yes
    ...    default=yes
    ${AZ_USERNAME}=    RW.Core.Import Secret
    ...    AZ_USERNAME
    ...    type=string
    ...    description=The azure service principal user ID.
    ...    pattern=\w*
    ${AZ_CLIENT_SECRET}=    RW.Core.Import Secret
    ...    AZ_CLIENT_SECRET
    ...    type=string
    ...    description=The service principal client secret used to authenticate with azure.
    ...    pattern=\w*
    ${AZ_TENANT}=    RW.Core.Import Secret
    ...    AZ_TENANT
    ...    type=string
    ...    description=The azure tenant ID used by the service principal to authenticate with azure.
    ...    pattern=\w*
    ${AZ_HISTORY_RANGE}=    RW.Core.Import User Variable
    ...    AZ_HISTORY_RANGE
    ...    type=string
    ...    description=The range of history to check for incidents in the activity log, in hours.
    ...    pattern=\w*
    ...    default=24
    ...    example=24
    ${AZ_LB_NAME}=    RW.Core.Import User Variable
    ...    AZ_LB_NAME
    ...    type=string
    ...    description=The name of the Azure loadbalancer resource, used to map to activity log events.
    ...    pattern=\w*
    ...    example=kubernetes-internal
    ...    example=kubernetes-internal
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${SKIP_K8S}    ${SKIP_K8S}
    Set Suite Variable    ${AZ_USERNAME}    ${AZ_USERNAME}
    Set Suite Variable    ${AZ_CLIENT_SECRET}    ${AZ_CLIENT_SECRET}
    Set Suite Variable    ${AZ_TENANT}    ${AZ_TENANT}
    Set Suite Variable    ${AZ_HISTORY_RANGE}    ${AZ_HISTORY_RANGE}
    Set Suite Variable    ${AZ_LB_NAME}    ${AZ_LB_NAME}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}
