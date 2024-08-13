#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_TENANT
# AZ_SUBSCRIPTION
# AZ_RESOURCE_GROUP
# APPSERVICE

# Log in to Azure CLI
az login --service-principal --username $AZ_USERNAME --password $AZ_SECRET_VALUE --tenant $AZ_TENANT

# Set the subscription
az account set --subscription $AZ_SUBSCRIPTION

# Fetch key metrics for the appservice
metrics=$(az monitor app-insights metrics show --resource-group $AZ_RESOURCE_GROUP --resource $APPSERVICE --metrics "CpuPercentage MemoryPercentage DiskPercentage")

# Check if any metrics are overutilized/unhealthy
overutilized=0

cpu_percentage=$(echo $metrics | jq -r '.value[0].timeseries[0].data[0].average')
if (( $(echo "$cpu_percentage > 80" | bc -l) )); then
    overutilized=1
fi

memory_percentage=$(echo $metrics | jq -r '.value[1].timeseries[0].data[0].average')
if (( $(echo "$memory_percentage > 80" | bc -l) )); then
    overutilized=1
fi

disk_percentage=$(echo $metrics | jq -r '.value[2].timeseries[0].data[0].average')
if (( $(echo "$disk_percentage > 80" | bc -l) )); then
    overutilized=1
fi

# Return 1 if any metrics are overutilized/unhealthy
exit $overutilized
