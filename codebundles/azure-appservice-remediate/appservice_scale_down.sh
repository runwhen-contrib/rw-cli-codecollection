#!/bin/bash

# Check if APPSERVICE environment variable is set
if [ -z "$APPSERVICE" ]; then
    echo "APPSERVICE environment variable is not set."
    exit 1
fi

# Get the current number of instances
current_instances=$(az webapp show --name "$APPSERVICE" --resource-group "$AZ_RESOURCE_GROUP" --query "siteConfig.numberOfWorkers" --output tsv)

# Check if the command was successful
if [ $? -ne 0 ]; then
    echo "Failed to get the current number of instances."
    exit 1
fi

# Calculate the new number of instances
new_instances=$((current_instances - 1))

# Scale the app service
az webapp update --name "$APPSERVICE" --resource-group "$AZ_RESOURCE_GROUP" --set siteConfig.numberOfWorkers=$new_instances

# Check if the command was successful
if [ $? -eq 0 ]; then
    echo "Successfully scaled $APPSERVICE to $new_instances instances."
else
    echo "Failed to scale $APPSERVICE."
    exit 1
fi