# Usage

# Infrastructure Setup
The terraform directory contains infrastructure used for testing. 

# Local Development Testing
export AZ_RESOURCE_GROUP=azure-vm-triage
export VMSCALESET=test-vmss
export AZURE_SUBSCRIPTION=$ARM_SUBSCRIPTION_ID
ro sli.robot
ro runbook.robot

- Perform some manual action like removing a node, or restarting a node. advanced testing would be to run apps that saturate the nodes resources. 


# RunWhen Local Discovery Testing


export RW_PAT=[]
export RW_WORKSPACE=[]
export RW_API_URL=[]