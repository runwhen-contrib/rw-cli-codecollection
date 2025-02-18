
## Swap Deployment Slots for App Service `${APP_SERVICE_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`
- Checks whether the plan supports deployment slots (Standard or Premium tier).
- Lists all available slots.
- If SOURCE_SLOT and TARGET_SLOT are not provided, it attempts to figure them out automatically, assuming:
    - The “production” slot is the default slot with "isSlot": false.
    - The non-production slot(s) have "isSlot": true.
    - If exactly one non-production slot exists, we set source to that slot and target to "production".
    - If there are multiple non-production slots, we fail unless the user specifies which ones to swap.