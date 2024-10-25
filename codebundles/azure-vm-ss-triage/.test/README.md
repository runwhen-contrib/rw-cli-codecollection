# Usage

# Local Testing
export AZ_RESOURCE_GROUP=azure-vm-triage
export VMSCALEDSET=test-vmss
export AZURE_SUBSCRIPTION=$ARM_SUBSCRIPTION_ID
ro sli.robot
ro runbook.robot

- Perform some manual action like removing a node, or 