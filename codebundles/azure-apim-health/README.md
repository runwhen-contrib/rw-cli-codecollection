
as login --use-device-code
## Test 1
export APP_SERVICE_NAME=azure-apim-health-f1
export AZ_RESOURCE_GROUP=azure-apim-health
export APIM_NAME=azure-apim-health-apim
export AZURE_RESOURCE_SUBSCRIPTION_ID=$ARM_SUBSCRIPTION_ID
export AZURE_CONFIG_DIR=/var/tmp/runwhen/azure-apim-health/runbook.robot/.azure
az login --use-device-code