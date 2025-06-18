# Azure DevOps Organization Configuration
# azure_devops_org = "your-org-name"
# azure_devops_org_url = "https://dev.azure.com/your-org-name"

# Azure Resource Configuration
resource_group = "rg-devops-org-health-test"
location = "East US"



# Testing Thresholds
agent_utilization_threshold = 80
license_utilization_threshold = 90


# Resource Tags
tags = {
  Environment = "test"
  Purpose     = "organization-health-testing"
  Owner       = "devops-team"
} 