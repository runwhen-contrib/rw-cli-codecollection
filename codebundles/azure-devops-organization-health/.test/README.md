## Testing Azure DevOps Organization Health

The `.test` directory contains infrastructure test code using Terraform to set up a test environment that validates organization-level health monitoring across various scenarios including agent pool capacity issues, license utilization problems, security policy violations, and platform service incidents.

## Required Permissions

### Azure Active Directory Permissions

The service principal or user account used for Terraform deployment requires the following Azure AD permissions:

#### Application Permissions (for creating test users)
- **Application.ReadWrite.All**: Create and manage Azure AD applications
- **User.ReadWrite.All**: Create and manage user accounts (for test user simulation)
- **Directory.ReadWrite.All**: Read and write directory data

#### Delegated Permissions (if using user account)
- **Application.ReadWrite.OwnedBy**: Create applications owned by the user
- **User.ReadWrite**: Create and manage users

### Azure Subscription Permissions

The service principal requires the following Azure RBAC roles:

#### Resource Group Level
- **Contributor**: Create and manage Azure resources in the test resource group
- **User Access Administrator**: Assign roles to service connections

#### Subscription Level (if creating resource groups)
- **Contributor**: Create resource groups and resources

### Azure DevOps Organization Permissions

The service principal or PAT token requires the following Azure DevOps permissions:

#### Organization-Level Permissions
- **Project Collection Administrators**: Full administrative access for testing
- **Project Collection Service Accounts**: Service account permissions

#### Specific Permissions Required
- **Agent Pools**: 
  - View agent pools
  - Manage agent pools
  - Create agent pools
  - Use agent pools
- **Build**: 
  - View builds
  - Edit builds
  - Queue builds
  - Manage build resources
- **Project and Team**: 
  - Create new projects
  - Delete projects (for cleanup)
  - Edit project-level information
- **Security**: 
  - View permissions
  - Manage permissions
  - View security groups
  - Manage security groups
- **Service Connections**: 
  - View service connections
  - Manage service connections
  - Create service connections
- **User Management**: 
  - View user entitlements
  - Manage user entitlements
  - Add users to organization
- **Variable Groups**: 
  - View variable groups
  - Manage variable groups
  - Create variable groups

#### Azure DevOps PAT Token Scopes

If using a Personal Access Token, ensure it has the following scopes:

- **Agent Pools**: Read & manage
- **Build**: Read & execute
- **Code**: Read & write
- **Project and Team**: Read, write, & manage
- **Release**: Read, write, execute, & manage
- **Service Connections**: Read, query, & manage
- **User Profile**: Read & write
- **Variable Groups**: Read, create, & manage
- **Work Items**: Read & write

### Service Principal Setup

#### 1. Create Azure AD Application and Service Principal

```bash
# Create the application
az ad app create --display-name "Azure DevOps Org Health Test SP"

# Get the application ID
APP_ID=$(az ad app list --display-name "Azure DevOps Org Health Test SP" --query "[0].appId" -o tsv)

# Create service principal
az ad sp create --id $APP_ID

# Get the service principal object ID
SP_OBJECT_ID=$(az ad sp list --display-name "Azure DevOps Org Health Test SP" --query "[0].id" -o tsv)

# Create client secret
az ad app credential reset --id $APP_ID --display-name "TerraformSecret"
```

#### 2. Assign Azure Permissions

```bash
# Assign Contributor role to subscription or resource group
az role assignment create --assignee $SP_OBJECT_ID --role "Contributor" --scope "/subscriptions/YOUR_SUBSCRIPTION_ID"

# Assign Application Administrator role in Azure AD (requires Global Admin)
az rest --method POST --uri "https://graph.microsoft.com/v1.0/directoryRoles/roleTemplateId=9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3/members" --body "{'@odata.id': 'https://graph.microsoft.com/v1.0/directoryObjects/$SP_OBJECT_ID'}"
```

#### 3. Add Service Principal to Azure DevOps

1. Navigate to Azure DevOps Organization Settings
2. Go to Users
3. Add the service principal using its Application ID
4. Assign **Project Collection Administrators** group membership

### Common Permission Issues and Solutions

#### Issue: "Authorization_RequestDenied: Insufficient privileges to complete the operation"
**Solution**: The service principal needs **Application.ReadWrite.All** permission in Azure AD
```bash
# Grant the permission (requires Global Admin)
az ad app permission add --id $APP_ID --api 00000003-0000-0000-c000-000000000000 --api-permissions 1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9=Role
az ad app permission admin-consent --id $APP_ID
```

#### Issue: "Agent pool [name] already exists"
**Solution**: Clean up existing test resources before running Terraform
```bash
# Clean up existing agent pools via Azure DevOps CLI
az devops project list --organization https://dev.azure.com/YOUR_ORG
az devops agent pool list --organization https://dev.azure.com/YOUR_ORG
# Delete conflicting pools manually or run terraform destroy first
```

#### Issue: "Project already exists"
**Solution**: Use unique project names or clean up existing test projects
```bash
# List existing projects
az devops project list --organization https://dev.azure.com/YOUR_ORG
# Delete test projects if they exist
az devops project delete --id PROJECT_ID --organization https://dev.azure.com/YOUR_ORG --yes
```

#### Issue: "Insufficient permissions to create service connections"
**Solution**: Ensure the service principal has proper Azure and Azure DevOps permissions
- Azure: Contributor role on target subscription/resource group
- Azure DevOps: Project Collection Administrators or specific service connection permissions

### Minimum Viable Permissions

For a minimal test setup with reduced permissions:

#### Azure AD (Minimum)
- **Application.ReadWrite.OwnedBy**: Create applications owned by the user
- **User.Read.All**: Read user information

#### Azure DevOps (Minimum)
- **Agent Pools**: View and manage
- **Build**: View and execute
- **Project and Team**: Create and manage projects
- **Service Connections**: View and manage

#### Azure (Minimum)
- **Contributor**: On the specific resource group used for testing

### Prerequisites for Testing

1. An existing Azure subscription
2. An existing Azure DevOps organization with administrative privileges
3. Permissions to create resources in Azure and Azure DevOps (see above)
4. Azure CLI installed and configured
5. Terraform installed (v1.0.0+)
6. Git installed for repository operations

### Azure DevOps Organization Setup (Before Running Terraform)

Before running Terraform, you need to configure your Azure DevOps organization with the necessary permissions:

#### 1. Organization Settings Configuration

1. Navigate to your Azure DevOps organization settings
2. Navigate to Users and Add the service principal as user with Basic Access level
3. Ensure the user has "Create new projects" permission set to "Allow"
4. Grant "Project Collection Administrators" permissions for comprehensive testing

#### 2. Agent Pool Management Permissions

1. Go to Organization Settings > Agent pools
2. Ensure your user (service principal) has permissions to:
   - Create and manage agent pools
   - View agent pool utilization
   - Configure agent pool security
   - Manage agent pool settings

#### 3. Licensing and User Management

1. Go to Organization Settings > Users
2. Ensure permissions to:
   - View user license assignments
   - Manage stakeholder access
   - View Visual Studio subscriptions
   - Access billing information

### Test Environment Setup

The test environment creates multiple scenarios to validate organization health monitoring:

#### Agent Pool Test Scenarios
- **Overutilized Pool**: Agent pool with high utilization (>90%)
- **Offline Agents**: Pool with multiple offline/unavailable agents
- **Undersized Pool**: Pool with insufficient capacity for demand
- **Misconfigured Pool**: Pool with security or configuration issues

#### License Utilization Test Scenarios
- **High License Usage**: Organization approaching license limits
- **Inactive Users**: Users with assigned licenses but no recent activity
- **Misaligned Access**: Users with incorrect access level assignments
- **Visual Studio Subscriber Waste**: VS subscribers not utilizing benefits

#### Security Policy Test Scenarios
- **Weak Security Policies**: Organization with permissive security settings
- **Missing Compliance**: Organization without required compliance policies
- **Over-permissioned Users**: Users with excessive organization permissions
- **Unsecured Service Connections**: Service connections with weak security

#### Platform Service Test Scenarios
- **Service Connectivity Issues**: Simulated API connectivity problems
- **Rate Limiting**: Scenarios triggering API rate limits
- **Performance Degradation**: Slow API response simulation
- **Authentication Failures**: Service principal authentication issues

#### Step 1: Configure Terraform Variables

Create a `terraform.tfvars` file in the `.test/terraform` directory:

```hcl
azure_devops_org           = "your-org-name"
azure_devops_org_url       = "https://dev.azure.com/your-org-name"
resource_group             = "your-resource-group"
location                   = "eastus"
agent_utilization_threshold = 80
license_threshold          = 90
test_user_count           = 25
tags = {
  Environment = "test"
  Purpose     = "organization-health-testing"
}
```

#### Step 2: Initialize and Apply Terraform

```bash
cd .test/terraform
terraform init
terraform apply
```

This creates:
- Multiple test projects for organization-wide testing
- Agent pools with different utilization patterns
- Test users with various license assignments
- Service connections with different security configurations
- Build pipelines across projects for capacity testing

#### Step 3: Generate Test Data (Automated)

The Terraform configuration includes scripts that automatically:
1. Create agent pools with different capacity scenarios
2. Generate test users with various license assignments
3. Configure security policies with different strengths
4. Set up service connections with security gaps
5. Create cross-project dependencies for testing

#### Step 4: Run Organization Health Tests

Execute the organization health runbook against different test scenarios:

```bash
# Test high agent utilization scenario
export AGENT_UTILIZATION_THRESHOLD=80
ro codebundles/azure-devops-organization-health/runbook.robot

# Test license utilization issues
export LICENSE_UTILIZATION_THRESHOLD=90
ro codebundles/azure-devops-organization-health/runbook.robot

# Test security policy violations
export SECURITY_CHECK_ENABLED=true
ro codebundles/azure-devops-organization-health/runbook.robot
```

### Test Scenarios and Expected Results

#### 1. Agent Pool Capacity Test
**Setup**: Agent pools with high utilization and offline agents
**Expected Issues**:
- Agent Pool Utilization Above Threshold (Severity 3)
- Offline Agents Detected (Severity 2)
- Insufficient Agent Capacity (Severity 4)
- Organization Health Score: <60

#### 2. License Utilization Test
**Setup**: Organization approaching license limits with inactive users
**Expected Issues**:
- License Utilization Above Threshold (Severity 3)
- Inactive Licensed Users (Severity 2)
- Misaligned Access Levels (Severity 2)
- Organization Health Score: 50-69

#### 3. Security Policy Violations Test
**Setup**: Organization with weak security configurations
**Expected Issues**:
- Weak Security Policies (Severity 4)
- Missing Compliance Requirements (Severity 3)
- Over-permissioned Users (Severity 3)
- Organization Health Score: <50

#### 4. Service Connectivity Test
**Setup**: Simulated API connectivity and authentication issues
**Expected Issues**:
- API Connectivity Problems (Severity 4)
- Authentication Failures (Severity 4)
- Performance Degradation (Severity 2)
- Organization Health Score: <40

#### 5. Cross-Project Dependencies Test
**Setup**: Multiple projects with interdependencies
**Expected Issues**:
- Cross-Project Pipeline Dependencies (Severity 2)
- Shared Resource Conflicts (Severity 2)
- Dependency Chain Failures (Severity 3)

#### 6. Platform Service Health Test
**Setup**: Organization-wide service health monitoring
**Expected Behavior**:
- Service incident detection
- Platform-wide issue identification
- Performance monitoring across projects
- Comprehensive service health reporting

### Validation Scripts

The test environment includes validation scripts to verify expected behavior:

#### `validate-agent-tests.sh`
Verifies that agent pool issues are properly detected:
```bash
./validate-agent-tests.sh
```

#### `validate-license-tests.sh`
Confirms license utilization issues are identified:
```bash
./validate-license-tests.sh
```

#### `validate-security-tests.sh`
Checks security policy violation detection:
```bash
./validate-security-tests.sh
```

#### `validate-service-tests.sh`
Tests service connectivity and health monitoring:
```bash
./validate-service-tests.sh
```

### Manual Test Scenarios

#### Creating Agent Pool Issues
1. Create an agent pool with minimal agents
2. Queue multiple builds to create high utilization
3. Take agents offline to simulate capacity issues

#### Simulating License Problems
1. Assign higher-tier licenses to inactive users
2. Create users with misaligned access levels
3. Set up Visual Studio subscribers without proper configuration

#### Testing Security Violations
1. Configure permissive organization policies
2. Grant excessive permissions to test users
3. Create unsecured service connections

### Cleanup

After testing, clean up resources:

```bash
cd .test/terraform
terraform destroy
```

This removes all test resources while preserving the original organization structure.

### Troubleshooting

#### Common Issues

1. **Terraform Authentication Errors**
   - Verify Azure CLI authentication: `az login`
   - Check Azure DevOps PAT token permissions
   - Ensure service principal has proper permissions

2. **Agent Pool Creation Failures**
   - Verify organization-level agent pool permissions
   - Check Azure DevOps licensing for agent pools
   - Ensure sufficient organization capacity

3. **License Assignment Issues**
   - Verify billing administrator permissions
   - Check available license types in organization
   - Ensure proper Visual Studio subscription setup

4. **Security Policy Configuration**
   - Verify Project Collection Administrator permissions
   - Check organization-level security settings
   - Ensure proper Azure AD integration

### Advanced Testing

#### Load Testing
Run organization health checks under high load:
```bash
# Simulate high API usage
for i in {1..10}; do
  ro codebundles/azure-devops-organization-health/runbook.robot &
done
```

#### Performance Testing
Measure organization health check performance:
```bash
time ro codebundles/azure-devops-organization-health/runbook.robot
```

#### Integration Testing
Test organization health with other Azure services:
```bash
# Test with Azure Monitor integration
export AZURE_MONITOR_ENABLED=true
ro codebundles/azure-devops-organization-health/runbook.robot
``` 