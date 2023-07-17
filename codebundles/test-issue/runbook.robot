*** Settings ***
Documentation       A codebundle for testing the issues feature. Purely for testing flow.
Metadata            Author    jon-funk
Metadata            Display Name    Test Issues
Metadata            Supports    Test

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Raise Full Issue
    [Documentation]    Always raises an issue with full content
    [Tags]    test
    ${issue}=    RW.CLI.Run Cli
    ...    cmd=echo "issue"
    ...    target_service=${GCLOUD_SERVICE}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${issue}
    ...    set_severity_level=4
    ...    set_issue_expected=We expected there to not be an issue.
    ...    set_issue_actual=We found a synthetic issue.
    ...    set_issue_title=Synthetic Issue Raised
    ...    set_issue_details=This issue was forcibly raised.
    ...    set_issue_next_steps=Next steps provided with: $_line
    ...    _line__raise_issue_if_contains=issue
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}


*** Keywords ***
Suite Initialization
    ${GCLOUD_SERVICE}=    RW.Core.Import Service    gcloud
    ...    type=string
    ...    description=The selected RunWhen Service to use for accessing services within a network.
    ...    pattern=\w*
    ...    example=gcloud-service.shared
    ...    default=gcloud-service.shared
    Set Suite Variable    ${GCLOUD_SERVICE}    ${GCLOUD_SERVICE}
