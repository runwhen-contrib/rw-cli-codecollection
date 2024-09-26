*** Settings ***
Documentation       This CodeBundle syncs images from public repostitories into an Azure Container Registry.
Metadata            Author    stewartshea
Metadata            Supports    Azure,ACR
Metadata            Display Name    Azure ACR Image Sync

Library             BuiltIn
Library             RW.Core
Library             RW.platform
Library             String
Library             OperatingSystem
Library             RW.CLI

Suite Setup         Suite Initialization


*** Tasks ***
Sync Container Images into Azure Container Registry `${ACR_REGISTRY}`
    [Documentation]    Synchronizes the latest container images into an ACR repository
    [Tags]    azure    acr    registry    runwhen
    ${az_acr_image_sync}=    RW.CLI.Run Bash File
    ...    bash_file=acr_sync_images.sh
    ...    env=${env}
    ...    secret__DOCKER_USERNAME=${DOCKER_USERNAME}
    ...    secret__DOCKER_TOKEN=${DOCKER_TOKEN}
    ...    include_in_history=False
    ...    timeout_seconds=1200
    RW.Core.Add Pre To Report    ACR Sync Output:\n${az_acr_image_sync.stdout}


*** Keywords ***
Suite Initialization
    ${ACR_REGISTRY}=    RW.Core.Import User Variable    ACR_REGISTRY
    ...    type=string
    ...    description=The name of the Azure Container Registry to import images into.
    ...    pattern=\w*
    ...    example=myacr.azurecr.io
    ...    default=myacr.azurecr.io
    ${IMAGE_MAPPINGS=}=    RW.Core.Import User Variable
    ...    IMAGE_MAPPINGS
    ...    type=string
    ...    description=Append the date to the image tag
    ...    pattern=\w*
    ...    example='[ {"source": "docker.io/library/nginx:latest", "destination": "test/nginx"}, {"source": "docker.io/library/alpine:3.14", "destination": "test2/alpine"} ]'
    ${USE_DATE_TAG_PATTERN}=    RW.Core.Import User Variable    USE_DATE_TAG_PATTERN
    ...    type=string
    ...    enum=[true,false]
    ...    description=Change the image tag to use the current date and time. Useful when importing 'latest' tags
    ...    pattern=\w*
    ...    default=false
    ${TAG_CONFLICT_HANDLING}=    RW.Core.Import User Variable
    ...    TAG_CONFLICT_HANDLING
    ...    type=string
    ...    enum=[overwrite,rename]
    ...    description=How to handle tags that already exist. Options are: overwrite (delete the tag and write a new copy), rename (append the date to the tag)
    ...    pattern=\w*
    ...    default=rename
    ${DOCKER_USERNAME}=    RW.Core.Import Secret
    ...    DOCKER_USERNAME
    ...    type=string
    ...    description=Docker username to use if rate limited by Docker.
    ...    pattern=\w*
    ${DOCKER_TOKEN}=    RW.Core.Import Secret
    ...    DOCKER_TOKEN
    ...    type=string
    ...    description=Docker token to use if rate limited by Docker.
    ...    pattern=\w*
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*

    # Escape double quotes for IMAGE_MAPPINGS to properly set it in the environment variable
    ${escaped_image_mappings}=    Replace String Using Regexp    ${IMAGE_MAPPINGS}    "    \\\"

    Set Suite Variable
    ...    ${env}
    ...    {"ACR_REGISTRY":"${ACR_REGISTRY}", "IMAGE_MAPPINGS":"${escaped_image_mappings}", "USE_DATE_TAG_PATTERN":"${USE_DATE_TAG_PATTERN}", "TAG_CONFLICT_HANDLING":"${TAG_CONFLICT_HANDLING}"}
