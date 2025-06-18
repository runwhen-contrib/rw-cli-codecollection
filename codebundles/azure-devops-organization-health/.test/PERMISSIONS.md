# Azure DevOps Organization Health Test - Required Permissions

This document outlines all the permissions required to run the Terraform-based test infrastructure for Azure DevOps organization health monitoring.

## Quick Setup Checklist

- [ ] Azure subscription Contributor role
- [ ] Azure DevOps Project Collection Administrator role
- [ ] Service Principal added to Azure DevOps organization
- [ ] PAT token with full scopes (if using PAT instead of SP)

## Detailed Permission Requirements

### 1. Azure Active Directory Permissions

#### For Service Principal (Optional - No longer required!)
```
No Azure AD permissions needed - the test infrastructure no longer creates users.
License monitoring queries existing organization users via Azure DevOps APIs.
```

### 2. Azure Subscription Permissions

#### RBAC Roles Required
```
Resource Group Level:
- Contributor (create/manage resources)
- User Access Administrator (assign roles to service connections)

Subscription Level (if creating RGs):
- Contributor
```

### 3. Azure DevOps Organization Permissions

#### Organization-Level Groups
- **Project Collection Administrators** (full access for testing)
- **Project Collection Service Accounts** (service permissions)

#### Granular Permissions
```
Agent Pools:
- View agent pools
- Manage agent pools  
- Create agent pools
- Use agent pools

Build:
- View builds
- Edit builds
- Queue builds
- Manage build resources

Project and Team:
- Create new projects
- Delete projects
- Edit project-level information

Security:
- View permissions
- Manage permissions
- View security groups
- Manage security groups

Service Connections:
- View service connections
- Manage service connections
- Create service connections

User Management:
- View user entitlements (for license analysis)
- Read organization users

Variable Groups:
- View variable groups
- Manage variable groups
- Create variable groups
```

### 4. PAT Token Scopes (Alternative to Service Principal)

If using Personal Access Token instead of Service Principal:

```
Required Scopes:
- Agent Pools: Read & manage
- Build: Read & execute  
- Code: Read & write
- Project and Team: Read, write, & manage
- Release: Read, write, execute, & manage
- Service Connections: Read, query, & manage
- User Profile: Read
- Variable Groups: Read, create, & manage
- Work Items: Read & write
```

## Setup Commands

### Create Service Principal

```bash
# Create Azure AD application
az ad app create --display-name "Azure DevOps Org Health Test SP"

# Get application ID
APP_ID=$(az ad app list --display-name "Azure DevOps Org Health Test SP" --query "[0].appId" -o tsv)

# Create service principal
az ad sp create --id $APP_ID

# Get service principal object ID
SP_OBJECT_ID=$(az ad sp list --display-name "Azure DevOps Org Health Test SP" --query "[0].id" -o tsv)

# Create client secret
az ad app credential reset --id $APP_ID --display-name "TerraformSecret"
```

### Assign Azure Permissions

```bash
# Assign Contributor role
az role assignment create \
  --assignee $SP_OBJECT_ID \
  --role "Contributor" \
  --scope "/subscriptions/YOUR_SUBSCRIPTION_ID"
```

### Grant API Permissions (No longer needed!)

```bash
# No Azure AD API permissions required!
# The test infrastructure now only creates Azure DevOps projects, agent pools, and service connections.
# License monitoring queries existing users instead of creating test users.
```

## Common Issues and Solutions

### Issue: "Agent pool [name] already exists"
**Root Cause**: Previous test run left resources that weren't cleaned up
**Solution**: Run `terraform destroy` or manually delete conflicting resources

### Issue: Service connection creation fails
**Root Cause**: Service principal lacks Azure subscription permissions
**Solution**: Assign Contributor role on target subscription/resource group

### Issue: "Insufficient permissions to view users"
**Root Cause**: Service principal lacks Azure DevOps user read permissions
**Solution**: Ensure service principal is added to Azure DevOps organization with appropriate permissions

## Minimum Permissions (Reduced Scope)

For environments with strict permission policies:

### Azure AD (Minimum)
- No Azure AD permissions required!

### Azure DevOps (Minimum)
- Agent Pools: View and manage
- Build: View and execute
- Project and Team: Create and manage projects
- Service Connections: View and manage
- User Profile: Read (for license analysis)

### Azure (Minimum)
- Contributor role on specific resource group only

## What This Test Infrastructure Creates

The simplified test infrastructure now only creates:

1. **Azure DevOps Projects** - For testing cross-project scenarios
2. **Agent Pools** - For testing capacity and utilization scenarios  
3. **Service Connections** - For testing security and connectivity scenarios
4. **Variable Groups** - For testing cross-project dependencies
5. **Build Pipelines** - For generating agent load

**What it NO LONGER creates:**
- ❌ Azure AD users
- ❌ Azure AD applications  
- ❌ User entitlements
- ❌ Group memberships

**License monitoring** now works by querying existing organization users via Azure DevOps APIs, which is more realistic and requires fewer permissions.

## Verification Commands

### Check Azure DevOps Access
```bash
# Set organization
az devops configure --defaults organization=https://dev.azure.com/YOUR_ORG

# Test project access
az devops project list

# Test agent pool access  
az devops agent pool list

# Test user read access (for license monitoring)
az devops user list
```

### Check Azure Permissions
```bash
# List role assignments
az role assignment list --assignee $SP_OBJECT_ID

# Test resource group access
az group show --name YOUR_RESOURCE_GROUP
```

## Security Best Practices

1. **Use Service Principal instead of PAT** for automated deployments
2. **Scope permissions to minimum required** for your testing needs
3. **Rotate secrets regularly** - set expiration dates on client secrets
4. **Use separate service principals** for different environments
5. **Monitor permission usage** with Azure AD audit logs
6. **Clean up test resources** after testing to avoid permission drift

## Support

For permission-related issues:
1. Check Azure DevOps organization settings for service principal access
2. Verify service principal has Contributor role on Azure subscription/resource group
3. Test permissions with Azure CLI commands before running Terraform 