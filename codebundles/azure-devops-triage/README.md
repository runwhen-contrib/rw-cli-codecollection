# Azure DevOps Triage

This codebundle runs a suite of health checks for Azure DevOps. It identifies:

- Agent Pool Availability
- Failed Pipeline Runs
- Long-Running Pipelines
- Queued Pipelines
- Repository Policies
- Service Connection Health

## Configuration

The runbook requires initialization to import necessary secrets and user variables. The following variables should be set:

- `AZURE_RESOURCE_GROUP`: The Azure resource group where DevOps resources are deployed
- `AZURE_DEVOPS_ORG`: Your Azure DevOps organization name
- `AZURE_DEVOPS_PROJECT`: Your Azure DevOps project name
- `DURATION_THRESHOLD`: Threshold for long-running pipelines (format: 60m, 2h) (default: 60m)
- `QUEUE_THRESHOLD`: Threshold for queued pipelines (format: 10m, 1h) (default: 30m)

## Testing

The `.test` directory contains infrastructure test code using Terraform to set up a test environment.

### Prerequisites for Testing

1. An existing Azure subscription
2. An existing Azure DevOps organization
3. Permissions to create resources in Azure and Azure DevOps
4. Azure CLI installed and configured
5. Terraform installed (v1.0.0+)

### Azure DevOps Organization Setup (Before Running Terraform)

Before running Terraform, you need to configure your Azure DevOps organization with the necessary permissions:

#### 1. Organization Settings Configuration

1. Navigate to your Azure DevOps organization settings
2. Add the user who will be running Terraform to the organization
3. Add the service principal as user that will be used by Terraform

#### 2. Agent Pool Permissions

1. Go to Organization Settings > Agent Pools > Security
2. Add your user (service principal) account with Administrator permissions

#### 3. Organization-Level Security Permissions

1. Go to Organization Settings > Security > Permissions
2. Find your user (service principal)
3. Ensure they have "Create new projects" permission set to "Allow"

These permissions are required for Terraform to successfully create and configure resources in your Azure DevOps organization.

### Test Environment Setup

The test environment creates:
- A new Azure DevOps project
- A new agent pool
- Git repositories with sample pipeline definitions
- Variable groups for testing

#### Step 1: Configure Terraform Variables

Create a `terraform.tfvars` file in the `.test/terraform` directory:

```hcl
azure_devops_org       = "your-org-name"
azure_devops_pat       = "your-personal-access-token"
azure_subscription_id  = "your-subscription-id"
azure_tenant_id        = "your-tenant-id"
azure_client_id        = "your-client-id"
azure_client_secret    = "your-client-secret"
resource_group_name    = "your-resource-group"
location               = "eastus"
```

#### Step 2: Initialize and Apply Terraform

```bash
cd .test/terraform
terraform init
terraform apply
```

#### Step 3: Set Up Self-Hosted Agent (Manual Step)

After Terraform creates the agent pool, you need to manually set up at least one self-hosted agent:

1. In Azure DevOps, navigate to Project Settings > Agent pools > [Your Pool Name]
2. Click "New agent"
3. Follow the instructions to download and configure the agent on your machine
4. Start the agent and verify it's online

Or follow these steps:
    a. Create a folder on your machine (e.g., mkdir ~/azagent && cd ~/azagent)
    b. Download the agent: curl -O https://vstsagentpackage.azureedge.net/agent/2.214.1/vsts-agent-linux-x64-2.214.1.tar.gz
    c. Extract: tar zxvf vsts-agent-linux-x64-2.214.1.tar.gz
    d. Configure: ./config.sh
        - Server URL: https://dev.azure.com/${var.azure_devops_org}
        - PAT: (your PAT) #generate PAT from the your azure devops org
        - Agent pool: ${azuredevops_agent_pool.test_pool.name}
    e. Run as a service: ./svc.sh install && ./svc.sh start

#### Step 4: Trigger Test Pipelines (Manual Step)

The test environment includes several pipeline definitions:
- Success Pipeline: A pipeline that completes successfully
- Failed Pipeline: A pipeline that intentionally fails
- Long-Running Pipeline: A pipeline that runs for longer than the threshold

To trigger these pipelines:
1. Navigate to Pipelines in your Azure DevOps project
2. Select each pipeline and click "Run pipeline"

#### Step 5: Run the Triage Runbook

Once the test environment is set up and pipelines are running, you can execute the triage runbook to verify it correctly identifies issues.

### Cleaning Up

To remove the test environment:

```bash
cd .test/terraform
terraform destroy
```

Note: This will not remove the Azure DevOps organization, as it was a prerequisite.

## Notes

- The codebundle uses the Azure CLI with the Azure DevOps extension to interact with Azure DevOps.
- Service principal authentication is used for Azure resources.
- The runbook focuses on identifying issues rather than fixing them.
- For queued pipelines, the threshold is measured from when the pipeline was created to the current time.
- For long-running pipelines, the threshold is measured from start time to finish time (or current time if still running).
