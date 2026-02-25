#!/bin/bash

# IMAGE_MAPPINGS JSON format:
# [
#   {"source": "docker.io/library/nginx:latest", "destination": "myrepo/nginx"},
#   {"source": "docker.io/library/alpine:3.14", "destination": "myrepo/alpine"}
# ]

# Initialize JSON output structure
output_json='{
  "updates_available": false,
  "image_updates": []
}'

# Define variables
UPDATE_COUNT=0  # Initialize count of images that require an update

# Environment variable for image mappings, format:
# IMAGE_MAPPINGS='[
#   {"source": "docker.io/library/nginx:latest", "destination": "myrepo/nginx"},
#   {"source": "docker.io/library/alpine:3.14", "destination": "myrepo/alpine"}
# ]'
IMAGE_MAPPINGS="${IMAGE_MAPPINGS:-"[]"}"
DOCKER_USERNAME="${DOCKER_USERNAME:-""}"  # Optional Docker username
DOCKER_TOKEN="${DOCKER_TOKEN:-""}"  # Optional Docker token

# Parse JSON into arrays for sources and destinations
SOURCES=($(echo "$IMAGE_MAPPINGS" | jq -r '.[] | .source'))
DESTINATIONS=($(echo "$IMAGE_MAPPINGS" | jq -r '.[] | .destination'))

# Get or set subscription ID
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
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
  
  echo "$dest_image:$dest_tag"
}

# Find the most recent tag in ACR that matches the image pattern
get_latest_acr_tag() {
  local repository="$1"
  local base_tag="$2"
  
  # List all tags for the repository
  TAGS=$(az acr repository show-tags --name "$ACR_REGISTRY" --repository "$repository" --query "[]" -o tsv)

  # Filter tags that start with the base tag
  MATCHING_TAGS=()
  for tag in $TAGS; do
    if [[ "$tag" == "$base_tag"* ]]; then
      MATCHING_TAGS+=("$tag")
    fi
  done

  # Find the tag with the most recent createdTime
  LATEST_TAG=""
  LATEST_TIME=""
  for tag in "${MATCHING_TAGS[@]}"; do
    CREATED_TIME=$(az acr manifest list-metadata --name "$repository" --registry "$ACR_REGISTRY" --query "[?tags[0]=='$tag'].createdTime" -o tsv)
    if [[ -z "$LATEST_TIME" || "$CREATED_TIME" > "$LATEST_TIME" ]]; then
      LATEST_TIME="$CREATED_TIME"
      LATEST_TAG="$tag"
    fi
  done

  echo "$LATEST_TAG"
}

# Check each image for updates
for i in "${!SOURCES[@]}"; do
  SOURCE_IMAGE="${SOURCES[$i]}"
  DEST_IMAGE="${DESTINATIONS[$i]}"
  
  # Resolve the destination image name and tag
  IMAGE_NAME_WITH_TAG=$(get_destination_image "$SOURCE_IMAGE" "$DEST_IMAGE")
  
  # Extract repository and base tag from IMAGE_NAME_WITH_TAG
  REPOSITORY=$(echo "$IMAGE_NAME_WITH_TAG" | cut -d: -f1)
  BASE_TAG=$(echo "$IMAGE_NAME_WITH_TAG" | cut -d: -f2)

  # Find the most recent tag in ACR that matches the base tag pattern
  LATEST_ACR_TAG=$(get_latest_acr_tag "$REPOSITORY" "$BASE_TAG")

  if [[ -n "$LATEST_ACR_TAG" ]]; then
    echo "Latest tag for $REPOSITORY matching base tag $BASE_TAG is $LATEST_ACR_TAG. Comparing timestamps..."

    # Get source image creation date using skopeo without pulling
    if [[ "$SOURCE_IMAGE" == docker.io/* && -n "$DOCKER_USERNAME" && -n "$DOCKER_TOKEN" ]]; then
        IMAGE_DETAILS=$(skopeo inspect --creds "${DOCKER_USERNAME}:${DOCKER_TOKEN}" "docker://${SOURCE_IMAGE}")
    else
        IMAGE_DETAILS=$(skopeo inspect "docker://${SOURCE_IMAGE}")
    fi

    SOURCE_CREATED=$(echo "$IMAGE_DETAILS" | jq -r '.Created')

    # Get ACR image creation date using the new command
    ACR_CREATED=$(az acr manifest list-metadata --name "$REPOSITORY" --registry "$ACR_REGISTRY" --query "[?tags[0]=='$LATEST_ACR_TAG'].createdTime" -o tsv)

    # Compare timestamps
    if [[ "$SOURCE_CREATED" > "$ACR_CREATED" ]]; then
      echo "Source image $SOURCE_IMAGE is newer than ACR image $ACR_REGISTRY/$REPOSITORY:$LATEST_ACR_TAG."
      ((UPDATE_COUNT++))  # Increment count for updates needed
    else
      echo "ACR image $ACR_REGISTRY/$REPOSITORY:$LATEST_ACR_TAG is up to date."
    fi
  else
    echo "No matching tag found for base tag $BASE_TAG in ACR. Marked as requiring update."
    ((UPDATE_COUNT++))  # Increment count for missing images
  fi
done

echo "Total images requiring an update: $UPDATE_COUNT"
