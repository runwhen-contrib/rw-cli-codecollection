*** Settings ***
Metadata          Author    stewartshea
Documentation     This CodeBundle counts the number of container images (from a configured list) outdated. It compares upstream images with those in the registry and counts the number that are outdated. 
Metadata          Supports     Azure,ACR
Metadata          Display Name     Outdated Azure Container Registry Image Count
Suite Setup       Suite Initialization
Library           BuiltIn
Library           RW.Core
Library           RW.platform
Library           String
Library           OperatingSystem
Library           RW.CLI


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
    ${USE_DOCKER_AUTH}=    RW.Core.Import User Variable
    ...    USE_DOCKER_AUTH
    ...    type=string
    ...    enum=[true,false]
    ...    description=Import the docker secret for authentication. Useful in bypassing rate limits. 
    ...    pattern=\w*
    ...    default=false
    Set Suite Variable    ${USE_DOCKER_AUTH}    ${USE_DOCKER_AUTH}
    Run Keyword If    "${USE_DOCKER_AUTH}" == "true"    Import Docker Secrets

    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*

    # Escape double quotes for IMAGE_MAPPINGS to properly set it in the environment variable
    ${escaped_image_mappings}=    Replace String Using Regexp    ${IMAGE_MAPPINGS}    "    \\\"
    Set Suite Variable    ${ACR_REGISTRY}    ${ACR_REGISTRY}
    Set Suite Variable    ${IMAGE_MAPPINGS}    ${IMAGE_MAPPINGS}
    Set Suite Variable    ${USE_DATE_TAG_PATTERN}    ${USE_DATE_TAG_PATTERN}
    Set Suite Variable
    ...    ${env}
    ...    {"ACR_REGISTRY":"${ACR_REGISTRY}", "IMAGE_MAPPINGS":"${escaped_image_mappings}", "USE_DATE_TAG_PATTERN":"${USE_DATE_TAG_PATTERN}", "TAG_CONFLICT_HANDLING":"${TAG_CONFLICT_HANDLING}"}

Import Docker Secrets
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

*** Tasks ***
Count Outdated Images in Azure Container Registry `${ACR_REGISTRY}`
    [Documentation]    Counts the number of images that need updating in ACR from the upstream source. 
    [Tags]    azure    acr    registry    runwhen
    ${az_acr_image_check}=    RW.CLI.Run Bash File
    ...    bash_file=check_for_image_updates.sh
    ...    env=${env}
    ...    secret__DOCKER_USERNAME=${DOCKER_USERNAME}
    ...    secret__DOCKER_TOKEN=${DOCKER_TOKEN}
    ...    include_in_history=False
    ...    timeout_seconds=1200
    ${total_outdated_images}=    RW.CLI.Run CLI
    ...    cmd=echo "${az_acr_image_check.stdout}" | grep "Total images requiring an update" | awk '{print $NF}'
    RW.Core.Push Metric    ${total_outdated_images.stdout}