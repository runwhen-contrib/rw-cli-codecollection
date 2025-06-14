*** Settings ***
Documentation       Analyse Azure Resource Graph.
Metadata            Author    stewartshea
Metadata            Display Name    Azure Resource Graph
Metadata            Supports    Azure    Resource Graph

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.ARG

Suite Setup         Suite Initialization

*** Tasks ***
Generate Dependency Graph using Azure Resource Graph for Subscription `${AZURE_RESOURCE_SUBSCRIPTION_ID}`
    [Documentation]    Fetch and evaluate active resource graph queries in the specified resource group.
    [Tags]    resource-graph    access:read-only

    ${resource_graph_run}=    RW.ARG.Create Azure Resource Graph
    ...    subscription=${AZURE_RESOURCE_SUBSCRIPTION_ID}
    ...    output=resource-graph.json
    ...    basic_mode=True

    RW.Core.Add Pre To Report    ${resource_graph_run}


*** Keywords ***
Suite Initialization
    ${AZURE_RESOURCE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_RESOURCE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure Subscription ID for the resource.  
    ...    pattern=\w*
    ...    default=""
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET
    ...    pattern=\w*
    Set Suite Variable    ${AZURE_RESOURCE_SUBSCRIPTION_ID}    ${AZURE_RESOURCE_SUBSCRIPTION_ID}
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_SUBSCRIPTION_ID":"${AZURE_RESOURCE_SUBSCRIPTION_ID}"}