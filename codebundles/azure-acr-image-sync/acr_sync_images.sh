#!/bin/bash

# Environment variable for image mappings, format:
# IMAGE_MAPPINGS='[
#   {"source": "docker.io/library/nginx:latest", "destination": "myrepo/nginx"},
#   {"source": "docker.io/library/alpine:3.14", "destination": "myrepo/alpine"}
# ]'
IMAGE_MAPPINGS="${IMAGE_MAPPINGS:-"[]"}"
# Enable date-based tag pattern (true/false)
USE_DATE_TAG_PATTERN="${USE_DATE_TAG_PATTERN:-false}"
# Conflict handling strategy: "overwrite" or "rename"
TAG_CONFLICT_HANDLING="${TAG_CONFLICT_HANDLING:-overwrite}"
# Optional Docker credentials for avoiding throttling
DOCKER_USERNAME="${DOCKER_USERNAME:-""}"  # Docker Hub username
DOCKER_TOKEN="${DOCKER_TOKEN:-""}"  # Docker Hub token

# Get current date and time in a format suitable for tags (e.g., YYYYMMDDHHMM)
if [[ "$USE_DATE_TAG_PATTERN" == "true" || "$TAG_CONFLICT_HANDLING" == "rename" ]]; then
  TAG_PATTERN=$(date +"%Y%m%d%H%M")
else
  TAG_PATTERN=""
fi

# Parse JSON into arrays for sources and destinations
SOURCES=($(echo "$IMAGE_MAPPINGS" | jq -r '.[] | .source'))
DESTINATIONS=($(echo "$IMAGE_MAPPINGS" | jq -r '.[] | .destination'))

# Check if AZURE_RESOURCE_SUBSCRIPTION_ID is set, otherwise get the current subscription ID
if [ -z "$AZURE_RESOURCE_SUBSCRIPTION_ID" ]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

# Set the subscription to the determined ID
echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }


# Function to extract destination image and apply optional tag pattern
get_destination_image() {
  local src_image="$1"
  local dest_image="$2"
  local conflict_handling="$3"
  
  # Extract the base image name and original tag
  src_tag=$(echo "$src_image" | awk -F: '{print $2}')
  
  # Check if a tag is already included in the destination image
  if [[ "$dest_image" == *:* ]]; then
    dest_tag=$(echo "$dest_image" | awk -F: '{print $2}')
    dest_image=$(echo "$dest_image" | awk -F: '{print $1}')
  else
    # Use the original source tag or "latest" if not provided
    if [[ -n "$src_tag" ]]; then
      dest_tag="$src_tag"
    else
      dest_tag="latest"
    fi
  fi
  
  # Append date-based tag pattern if necessary
  if [[ "$conflict_handling" == "rename" || -n "$TAG_PATTERN" ]]; then
    echo "$dest_image:${dest_tag}-${TAG_PATTERN}"
  else
    echo "$dest_image:$dest_tag"
  fi
}

# Import each image
for i in "${!SOURCES[@]}"; do
  SOURCE_IMAGE="${SOURCES[$i]}"
  DEST_IMAGE="${DESTINATIONS[$i]}"
  
  # Resolve the destination image name and tag
  IMAGE_NAME_WITH_TAG=$(get_destination_image "$SOURCE_IMAGE" "$DEST_IMAGE" "$TAG_CONFLICT_HANDLING")
  
  # Extract repository and tag from IMAGE_NAME_WITH_TAG
  REPOSITORY=$(echo "$IMAGE_NAME_WITH_TAG" | cut -d: -f1)
  TAG=$(echo "$IMAGE_NAME_WITH_TAG" | cut -d: -f2)

  # Check if the tag already exists in the ACR
  EXISTING_TAG=$(az acr repository show-tags --name "$ACR_REGISTRY" --repository "$REPOSITORY" --query "[?@=='$TAG']" -o tsv)
  if [[ -n "$EXISTING_TAG" ]]; then
    if [[ "$TAG_CONFLICT_HANDLING" == "overwrite" ]]; then
      echo "Tag $REPOSITORY:$TAG already exists in ACR. Overwriting by deleting the existing tag..."
      az acr repository delete --name "$ACR_REGISTRY" --image "$IMAGE_NAME_WITH_TAG" --yes
    elif [[ "$TAG_CONFLICT_HANDLING" == "rename" ]]; then
      echo "Tag $REPOSITORY:$TAG already exists in ACR. Renaming to avoid conflict..."
      # Regenerate the image name with a new date-based tag
      IMAGE_NAME_WITH_TAG=$(get_destination_image "$SOURCE_IMAGE" "$DEST_IMAGE" "rename")
    fi
  fi

  # Initialize the command with the basic az acr import structure
  cmd="az acr import --name $ACR_REGISTRY --source $SOURCE_IMAGE --image $IMAGE_NAME_WITH_TAG"

  # Conditionally add Docker authentication if the repository is from Docker Hub and credentials are set
  if [[ $SOURCE_IMAGE == docker.io/* ]]; then
    if [[ -n "$DOCKER_USERNAME" && -n "$DOCKER_TOKEN" ]]; then
      echo "Docker Hub image detected. Using Docker credentials for import..."
      cmd+=" --username ${DOCKER_USERNAME} --password ${DOCKER_TOKEN}"
    else
      echo "Warning: Docker Hub image detected but credentials are not set. Throttling might occur."
    fi
  else
    echo "Non-Docker Hub image detected. No Docker credentials needed."
  fi

  # Execute the import command
  echo "Importing $SOURCE_IMAGE as $IMAGE_NAME_WITH_TAG into $ACR_REGISTRY..."
  
  eval "$cmd"

  if [[ $? -ne 0 ]]; then
    echo "Failed to import $SOURCE_IMAGE"
  else
    echo "Successfully imported $SOURCE_IMAGE as $IMAGE_NAME_WITH_TAG"
  fi
done

echo "All images processed."
