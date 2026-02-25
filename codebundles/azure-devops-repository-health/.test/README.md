## Testing Azure DevOps Repository Health

The `.test` directory contains infrastructure test code using Terraform to set up a test environment that validates repository health monitoring across various scenarios including security misconfigurations, code quality issues, and collaboration problems.

### Prerequisites for Testing

1. An existing Azure subscription
2. An existing Azure DevOps organization
3. Permissions to create resources in Azure and Azure DevOps
4. Azure CLI installed and configured
5. Terraform installed (v1.0.0+)
6. Git installed for repository operations

### Azure DevOps Organization Setup (Before Running Terraform)

Before running Terraform, you need to configure your Azure DevOps organization with the necessary permissions:

#### 1. Organization Settings Configuration

1. Navigate to your Azure DevOps organization settings
2. Navigate to Users and Add the service principal as user with Basic Access level
3. Ensure the user has "Create new projects" permission set to "Allow"

#### 2. Repository Permissions

1. Go to Organization Settings > Security > Permissions
2. Ensure your user (service principal) has permissions to:
   - Create repositories
   - Manage branch policies
   - Create pull requests
   - Manage repository permissions

### Test Environment Setup

The test environment creates multiple scenarios to validate repository health monitoring:

#### Security Test Scenarios
- **Unprotected Repository**: No branch protection policies
- **Weak Protection**: Minimal branch policies with security gaps
- **Over-Permissioned Repository**: Excessive permissions for testing
- **Self-Approval Repository**: Policies allowing self-approval

#### Code Quality Test Scenarios
- **No Build Validation**: Repository without CI/CD pipelines
- **High Failure Rate**: Repository with intentionally failing builds
- **Large Repository**: Repository with large files to test performance monitoring
- **Poor Structure**: Repository with bad naming conventions and organization

#### Collaboration Test Scenarios
- **Abandoned PRs**: Pull requests that are left open for extended periods
- **Single Reviewer**: Repository with review bottlenecks
- **Quick Merges**: PRs merged too quickly without proper review
- **Stale Branches**: Multiple old branches for cleanup testing

#### Step 1: Configure Terraform Variables

Create a `terraform.tfvars` file in the `.test/terraform` directory:

```hcl
azure_devops_org       = "your-org-name"
azure_devops_org_url   = "https://dev.azure.com/your-org-name"
resource_group         = "your-resource-group"
location               = "eastus"
tags = {
  Environment = "test"
  Purpose     = "repository-health-testing"
}
```

#### Step 2: Initialize and Apply Terraform

```bash
cd .test/terraform
terraform init
terraform apply
```

This creates:
- Test project with multiple repositories
- Repositories with different security configurations
- Sample pull requests in various states
- Build pipelines with different success rates
- Branch structures for testing cleanup scenarios

#### Step 3: Generate Test Data (Automated)

The Terraform configuration includes scripts that automatically:
1. Create repositories with different security postures
2. Generate sample commits and branches
3. Create pull requests in various states (active, abandoned, merged)
4. Set up build pipelines with different failure patterns
5. Configure branch policies with security gaps

#### Step 4: Run Repository Health Tests

Execute the repository health runbook against different test repositories:

```bash
# Test unprotected repository
export AZURE_DEVOPS_REPO="test-unprotected-repo"
ro codebundles/azure-devops-repository-health/runbook.robot

# Test over-permissioned repository  
export AZURE_DEVOPS_REPO="test-overpermissioned-repo"
ro codebundles/azure-devops-repository-health/runbook.robot

# Test repository with collaboration issues
export AZURE_DEVOPS_REPO="test-collaboration-issues-repo"
ro codebundles/azure-devops-repository-health/runbook.robot
```

### Test Scenarios and Expected Results

#### 1. Unprotected Repository Test
**Setup**: Repository with no branch protection policies
**Expected Issues**:
- Missing Required Reviewers Policy (Severity 3)
- Missing Build Validation Policy (Severity 3)
- Unprotected Default Branch (Severity 4)
- Repository Health Score: <50

#### 2. Weak Security Configuration Test
**Setup**: Repository with minimal, poorly configured policies
**Expected Issues**:
- Insufficient Required Reviewers (Severity 2)
- Creator Can Approve Own Changes (Severity 2)
- Reviews Not Reset on New Changes (Severity 2)
- Repository Health Score: 50-69

#### 3. Code Quality Issues Test
**Setup**: Repository with no builds and quality problems
**Expected Issues**:
- No Build Definitions Found (Severity 3)
- No Test Results Found (Severity 3)
- High Build Failure Rate (Severity 3)
- Repository Health Score: <70

#### 4. Branch Management Problems Test
**Setup**: Repository with poor branch organization
**Expected Issues**:
- Excessive Number of Branches (Severity 2)
- Poor Branch Naming Conventions (Severity 2)
- Stale Branches Detected (Severity 1)
- No Standard Workflow Branches (Severity 2)

#### 5. Collaboration Issues Test
**Setup**: Repository with problematic PR patterns
**Expected Issues**:
- High Pull Request Abandonment Rate (Severity 3)
- Long-Lived Pull Requests (Severity 2)
- High Rate of Unreviewed Pull Requests (Severity 3)
- Single Reviewer Bottleneck (Severity 2)

#### 6. Performance Issues Test
**Setup**: Repository with size and performance problems
**Expected Issues**:
- Repository Size Exceeds Threshold (Severity 2)
- Large Repository May Need Git LFS (Severity 2)
- Excessive Branch Count Impacts Performance (Severity 2)

#### 7. Critical Security Investigation Test
**Setup**: Repository triggering critical investigation
**Expected Behavior**:
- Critical investigation script execution
- Security incident analysis
- Detailed remediation steps
- Comprehensive audit trail

### Validation Scripts

The test environment includes validation scripts to verify expected behavior:

#### `validate-security-tests.sh`
Verifies that security misconfigurations are properly detected:
```bash
./validate-security-tests.sh
```

#### `validate-quality-tests.sh`
Confirms code quality issues are identified:
```bash
./validate-quality-tests.sh
```

#### `validate-collaboration-tests.sh`
Checks collaboration pattern detection:
```bash
./validate-collaboration-tests.sh
```

#### `validate-performance-tests.sh`
Tests performance issue identification:
```bash
./validate-performance-tests.sh
```

### Manual Test Scenarios

#### Creating Problematic Pull Requests
1. Create a PR with suspicious title containing "password" or "secret"
2. Create long-lived PRs (>14 days old)
3. Create PRs with self-approvals
4. Create abandoned PRs

#### Simulating Security Issues
1. Remove branch protection policies
2. Add excessive repository permissions
3. Create branches with suspicious names
4. Commit large files without Git LFS

#### Testing Performance Issues
1. Create repositories >500MB
2. Add 100+ branches
3. Create very frequent small commits
4. Add large binary files

### Cleaning Up

To remove the test environment:

```bash
cd .test/terraform
terraform destroy
```

### Automated Testing with Task

Use the included Taskfile for automated testing:

```bash
# Run full test suite
task default

# Build test infrastructure
task build-infra

# Clean up test environment
task clean

# Run specific test scenarios
task test-security
task test-quality
task test-collaboration
task test-performance
```

### Expected Test Results Summary

| Test Scenario | Expected Health Score | Critical Issues | Key Detections |
|---------------|----------------------|-----------------|----------------|
| Unprotected Repo | <50 | Yes | Missing branch protection |
| Weak Security | 50-69 | No | Policy configuration gaps |
| Quality Issues | <70 | Yes | No builds/tests |
| Branch Problems | 60-80 | No | Poor organization |
| Collaboration Issues | 50-70 | No | PR pattern problems |
| Performance Issues | 70-85 | No | Size/structure issues |
| Healthy Repo | 90-100 | No | All checks pass |

### Troubleshooting Tests

If tests don't produce expected results:

1. **Check Permissions**: Ensure service principal has all required permissions
2. **Verify Infrastructure**: Confirm all Terraform resources were created successfully
3. **Review Logs**: Check Azure DevOps audit logs for API call issues
4. **Validate Data**: Ensure test data was generated correctly
5. **Check Thresholds**: Verify configuration thresholds match test scenarios

### Notes

- Tests are designed to validate both positive and negative scenarios
- Critical investigation only triggers when severity 3+ issues are detected
- Health scores are calculated based on weighted issue severity
- Some tests require manual verification of remediation steps
- Test environment includes realistic data patterns for accurate validation 