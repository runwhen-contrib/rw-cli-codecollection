# Azure ACR Image Sync

## Runbook: Azure ACR Image Sync

**Purpose**:  
This CodeBundle synchronizes container images from public repositories into an Azure Container Registry (ACR). It allows for automated image synchronization, applying an optional date tag, and handling tag conflicts based on user preferences.

**Example Inputs**:

- **ACR_REGISTRY**:  
  - *Type*: `string`  
  - *Description*: The name of the Azure Container Registry to import images into.  
  - *Pattern*: `\w*`  
  - *Example*: `myacr.azurecr.io`  
  - *Default*: `myacr.azurecr.io`  

- **IMAGE_MAPPINGS**:  
  - *Type*: `string`  
  - *Description*: JSON list of image source and destination mappings.  
  - *Example*: `[{"source": "docker.io/library/nginx:latest", "destination": "test/nginx"}, {"source": "docker.io/library/alpine:3.14", "destination": "test2/alpine"}]`  
  - *Default*: See example above.  

- **USE_DATE_TAG_PATTERN**:  
  - *Type*: `bool`  
  - *Description*: Whether to append the date to the image tag.  
  - *Default*: `False`  

- **TAG_CONFLICT_HANDLING**:  
  - *Type*: `enum (overwrite, rename)`  
  - *Description*: How to handle tags that already exist.  
  - *Default*: `rename`  

- **DOCKER_USERNAME** & **DOCKER_TOKEN**:  
  - *Type*: `string`  
  - *Description*: Docker credentials for authentication in case of rate limits.  

- **azure_credentials**:  
  - *Type*: `string`  
  - *Description*: Secret containing `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_SUBSCRIPTION_ID`.

**Task Description**:  
The task **"Sync Container Images into Azure Container Registry `${ACR_REGISTRY}`"** runs a bash script (`acr_sync_images.sh`) to sync container images into the specified ACR registry, using the provided environment variables and secrets.

--

## SLI: Outdated Azure Container Registry Image Count

**Purpose**:  
This CodeBundle counts the number of outdated container images in an Azure Container Registry (ACR) by comparing the images in ACR against the upstream sources. It provides an overview of which images need updating.

**Example Inputs**:

- **ACR_REGISTRY**:  
  - *Type*: `string`  
  - *Description*: The name of the Azure Container Registry to analyze.  
  - *Pattern*: `\w*`  
  - *Example*: `myacr.azurecr.io`  
  - *Default*: `myacr.azurecr.io`  

- **IMAGE_MAPPINGS**:  
  - *Type*: `string`  
  - *Description*: JSON list of image source and destination mappings.  
  - *Example*: `[{"source": "docker.io/library/nginx:latest", "destination": "test/nginx"}, {"source": "docker.io/library/alpine:3.14", "destination": "test2/alpine"}]`  
  - *Default*: See example above.  

- **USE_DATE_TAG_PATTERN**:  
  - *Type*: `bool`  
  - *Description*: Whether to append the date to the image tag.  
  - *Default*: `False`  

- **TAG_CONFLICT_HANDLING**:  
  - *Type*: `enum (overwrite, rename)`  
  - *Description*: How to handle tags that already exist.  
  - *Default*: `rename`  

- **DOCKER_USERNAME** & **DOCKER_TOKEN**:  
  - *Type*: `string`  
  - *Description*: Docker credentials for authentication in case of rate limits.  

- **azure_credentials**:  
  - *Type*: `string`  
  - *Description*: Secret containing `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_SUBSCRIPTION_ID`.

**Task Description**:  
The task **"Count Outdated Images in Azure Container Registry `${ACR_REGISTRY}`"** runs a bash script (`check_for_image_updates.sh`) to count outdated images and outputs the total count that require updates in ACR. The result is pushed as a metric.
