#!/bin/bash

# Variables
if [ -z "$APPSERVICE" ]; then
    echo "APPSERVICE environment variable is not set."
    exit 1
fi

echo "Restarting App Service: $APPSERVICE in Resource Group: $AZ_RESOURCE_GROUP"
az webapp restart --name "$APPSERVICE" --resource-group "$AZ_RESOURCE_GROUP"
if [ $? -eq 0 ]; then
    echo "App Service $APPSERVICE restarted successfully."
else
    echo "Failed to restart App Service $APPSERVICE."
    exit 1
fi
