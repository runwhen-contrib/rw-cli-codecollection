# Usage

# Infrastructure Setup
The terraform directory contains infrastructure used for testing. 

# Local Development Testing
export AZ_RESOURCE_GROUP=azure-vm-triage
export VMSCALESET=test-vmss
export AZURE_SUBSCRIPTION=$ARM_SUBSCRIPTION_ID
ro sli.robot
ro runbook.robot

Perform an azure login on the command line to interact with the infrastructure provisioned by Terraform. 

To test or generate issues, perform some manual action like removing a node, or restarting a node. Advanced testing could be done with some apps that saturate the nodes resources - though only basic testing is required at this point in time. 


# Testing
A `Taskfile.yaml` exists with numerous tasks for testing: 
```
task: Available tasks for this project:
* check-and-cleanup-terraform:       Check and clean up deployed Terraform infrastructure if it exists
* check-terraform-infra:             Check if Terraform has any deployed infrastructure in the terraform subdirectory
* check-unpushed-commits:            Check if outstanding commits or file updates need to be pushed before testing.
* clean:                             Run cleanup tasks
* clean-rwl-discovery:               Check and clean up RunWhen Local discovery output
* cleanup-terraform-infra:           Cleanup deployed Terraform infrastructure
* default:                           Run/refresh config
* delete-slxs:                       Delete SLX objects from the appropriate URL
* generate-rwl-config:               Generate RunWhen Local configuration (workspaceInfo.yaml)
* run-rwl-discovery:                 Run RunWhen Local Discovery on test infrastructure
* upload-slxs:                       Upload SLX files to the appropriate URL
* validate-generation-rules:         Validate YAML files in .runwhen/generation-rules
```

The default tasks will build a basic RunWhen Local configuration file (workspaceInfo.yaml) and perform discovery of the resources with only this specific codebundle configured. For this to function properly, the gen rules must be pushed to the GitHub repo / branch (which is automatically configured in workspaceInfo.yaml). The `check-unpushed-commits` task will verify if a push is required before running the discovery process. 
Once discovery has been performed, an `output` directory will contain the automatically generated configuration content, which can be uploaded to a test workspace with the `upload-slxs` task. Finally, the cleanup tasks can be used to help remove these slxs and tear down the infrastructure. 

The full set of env vars used for testing are: 
```
export ARM_SUBSCRIPTION_ID=[]
export AZ_TENANT_ID=[]
export AZ_CLIENT_SECRET=[]
export AZ_CLIENT_ID=[]
export AZ_SECRET_ID=[]

export RW_PAT=[]
export RW_WORKSPACE=[]
export RW_API_URL=[]
```