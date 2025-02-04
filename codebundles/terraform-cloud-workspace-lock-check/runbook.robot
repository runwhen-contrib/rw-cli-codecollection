*** Settings ***
Documentation       Check whether the Terraform Cloud Workspace is in a locked state.
Metadata            Author    nmadhok
Metadata            Display Name    Terraform Cloud Workspace Lock Check
Metadata            Supports    Terraform Cloud

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Checking whether the Terraform Cloud Workspace '${TERRAFORM_WORKSPACE_NAME}' is in a locked state
    [Documentation]    Use curl to check whether the Terraform Cloud Workspace is in a locked state
    [Tags]    terraform    cloud    workspace    lock
    ${curl_rsp}=    RW.CLI.Run Cli
    ...    cmd=TERRAFORM_API_TOKEN_VALUE=$(cat $TERRAFORM_API_TOKEN) && curl --header "Authorization: Bearer $TERRAFORM_API_TOKEN_VALUE" --header "Content-Type: application/vnd.api+json" -s '${TERRAFORM_API_URL}/organizations/${TERRAFORM_ORGANIZATION_NAME}/workspaces/${TERRAFORM_WORKSPACE_NAME}'
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__TERRAFORM_API_TOKEN=${TERRAFORM_API_TOKEN}
    ${locked}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${curl_rsp}
    ...    extract_path_to_var__locked=data.attributes.locked
    ...    locked__raise_issue_if_neq=False
    ...    set_issue_expected=Terraform Cloud Workspace is not locked
    ...    set_issue_actual=Terraform Cloud Workspace is locked
    ...    set_issue_title=Terraform Cloud Workspace Lock issue
    ...    set_severity_level=4
    ...    assign_stdout_from_var=locked
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}
    RW.Core.Add Pre To Report    Locked: ${locked.stdout}


*** Keywords ***
Suite Initialization

    ${TERRAFORM_API_URL}=    RW.Core.Import User Variable    TERRAFORM_API_URL
    ...    type=string
    ...    description=What URL to perform requests against.
    ...    pattern=\w*
    ...    default=https://app.terraform.io/api/v2
    ...    example=https://app.terraform.io/api/v2

    ${TERRAFORM_API_TOKEN}=    RW.Core.Import Secret    TERRAFORM_API_TOKEN
    ...    type=string
    ...    description=Bearer Token to use for authentication to Terraform Cloud API
    ...    pattern=\w*

    ${TERRAFORM_ORGANIZATION_NAME}=    RW.Core.Import User Variable    TERRAFORM_ORGANIZATION_NAME
    ...    type=string
    ...    description=Name of the organization in Terraform Cloud.
    ...    pattern=\w*
    ...    default=
    ...    example=my-organization

    ${TERRAFORM_WORKSPACE_NAME}=    RW.Core.Import User Variable    TERRAFORM_WORKSPACE_NAME
    ...    type=string
    ...    description=Name of the workspace in Terraform Cloud.
    ...    pattern=\w*
    ...    default=
    ...    example=my-workspace

    Set Suite Variable    ${TERRAFORM_API_URL}    ${TERRAFORM_API_URL}
    Set Suite Variable    ${TERRAFORM_API_TOKEN}    ${TERRAFORM_API_TOKEN}
    Set Suite Variable    ${TERRAFORM_ORGANIZATION_NAME}    ${TERRAFORM_ORGANIZATION_NAME}
    Set Suite Variable    ${TERRAFORM_WORKSPACE_NAME}    ${TERRAFORM_WORKSPACE_NAME}
    Set Suite Variable    ${env}    {"TERRAFORM_API_TOKEN":"./${TERRAFORM_API_TOKEN.key}"}
