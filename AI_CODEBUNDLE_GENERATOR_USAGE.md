# 🤖 AI Codebundle Generator - Usage Guide

The AI Codebundle Generator is now live in this repository! It automatically creates complete codebundles from GitHub issues using AI and existing templates.

## 🚀 How to Use

### Step 1: Create an Issue

You have two options:

#### Option A: Use the Issue Template
1. Go to **Issues** → **New Issue**
2. Select **"Auto-Generate Codebundle"** template
3. Fill out the template with your requirements

#### Option B: Manual Issue Creation
1. Create a new issue with your requirements
2. Add the `auto-generate-codebundle` label
3. Include platform, service type, and tasks in the description

### Step 2: Watch the Magic Happen

Once you add the `auto-generate-codebundle` label:

1. 🏷️ **Label Applied** → GitHub Action triggers automatically
2. 🤖 **Processing** → `codebundle-processing` label added
3. 📝 **Generation** → AI analyzes your requirements and generates code
4. 🔄 **PR Created** → Pull request created with complete codebundle
5. ✅ **Ready** → `codebundle-generated` and `awaiting-review` labels added

### Step 3: Review and Merge

1. Review the generated pull request
2. Test the codebundle locally if needed
3. Make any adjustments
4. Merge when ready!

## 📋 Issue Format

### Required Information

Your issue should include:

```markdown
## Platform
Azure | AWS | GCP | Kubernetes

## Service/Resource Type  
Network Security Groups | Storage Accounts | Load Balancers | etc.

## Purpose
Health | Triage | Integrity | Ops

## Tasks to Implement
1. **Task Name**: Clear description of what this should do
2. **Another Task**: Another clear description
```

### Example Issue

```markdown
## Platform: Azure

## Service/Resource Type: Network Security Groups

## Purpose: Integrity

## Tasks to Implement:

1. **Detect Manual NSG Changes**
   - Compare current NSG rules with repo-managed desired state
   - Flag discrepancies that indicate out-of-band changes

2. **Subnet Egress Validation**
   - Confirm traffic flow from each subnet by testing NSG and VNet rule enforcement

3. **Log Activity Audit for NSG/Firewall Changes**
   - Query activity logs to identify whether firewall/NSG changes were pushed through CI/CD pipeline vs. manual actors
```

## 🎯 What Gets Generated

For the example above, you'll get:

```
codebundles/azure-network-security-integrity/
├── detect_manual_nsg_changes.sh           # Bash script for NSG comparison
├── subnet_egress_validation.sh            # Bash script for traffic validation  
├── log_activity_audit_for_nsg_firewall_changes.sh  # Bash script for log analysis
├── runbook.robot                          # Robot Framework tasks
├── meta.yaml                              # Command metadata
├── README.md                              # Complete documentation
└── .cursorrules                           # Code assistance rules
```

## 🏷️ Label Workflow

| Label | Meaning | Applied By |
|-------|---------|------------|
| `auto-generate-codebundle` | **Trigger** - Starts the generation process | You (manual) |
| `codebundle-processing` | **In Progress** - Generation is running | System (auto) |
| `codebundle-generated` | **Success** - Codebundle created successfully | System (auto) |
| `awaiting-review` | **Ready** - PR ready for review | System (auto) |
| `codebundle-failed` | **Failed** - Generation encountered an error | System (auto) |

## 🔧 Configuration

The system uses `.github/codebundle-generator-config.yml` for configuration:

```yaml
# Platform detection keywords
platforms:
  azure:
    keywords: ["azure", "az ", "aks", "acr", "nsg", "vnet"]
  aws:
    keywords: ["aws", "eks", "ec2", "s3", "lambda", "vpc"]
  k8s:
    keywords: ["kubernetes", "k8s", "kubectl", "pod"]

# Service type detection  
service_types:
  network-security:
    keywords: ["firewall", "nsg", "network security", "security group"]
  storage:
    keywords: ["storage", "disk", "volume", "blob", "bucket"]

# Purpose detection
purposes:
  integrity:
    keywords: ["integrity", "audit", "compliance", "validation"]
  health:
    keywords: ["health", "monitoring", "check", "status"]
```

## 📝 Complete Example Workflow

### 1. Create Issue for Azure NSG Integrity

**Title:** `[Auto-Generate] Azure NSG Integrity Monitoring`

**Body:**
```markdown
## Platform: Azure

## Service/Resource Type: Network Security Groups

## Purpose: Integrity

## Tasks to Implement:

1. **Detect Manual NSG Changes**
   - Compare current NSG rules with Infrastructure as Code definitions
   - Flag any rules that were added/modified outside of the CI/CD pipeline
   - Generate alerts for unauthorized changes

2. **Subnet Egress Validation**
   - Test actual traffic flow against NSG rule expectations
   - Validate that egress rules are working as intended
   - Check for overly permissive rules

3. **Log Activity Audit**
   - Query Azure Activity Logs for NSG modifications
   - Identify who made changes and when
   - Correlate changes with deployment pipeline activities

## Additional Context
This codebundle should help maintain security compliance by ensuring all NSG changes go through proper approval processes.
```

**Labels:** `auto-generate-codebundle`

### 2. System Processing

The GitHub Action will:

1. **Parse Requirements:**
   - Platform: `azure`
   - Service Type: `network-security`
   - Purpose: `integrity`
   - Codebundle Name: `azure-network-security-integrity`

2. **Find Templates:**
   - Looks at existing `azure-*` codebundles
   - Uses `azure-aks-triage` (has NSG logic) as primary template
   - Analyzes `azure-acr-health` for security patterns

3. **Generate Code:**
   - Creates 3 bash scripts for the specified tasks
   - Generates Robot Framework tasks
   - Creates comprehensive documentation

### 3. Generated Output

**Pull Request Created:** `🤖 Auto-generated codebundle: azure-network-security-integrity`

**Files Generated:**
- `detect_manual_nsg_changes.sh` - Compares NSG rules with desired state
- `subnet_egress_validation.sh` - Tests traffic flow validation
- `log_activity_audit.sh` - Queries Azure Activity Logs
- `runbook.robot` - Complete Robot Framework tasks
- `meta.yaml` - Command definitions and documentation links
- `README.md` - Usage instructions and documentation
- `.cursorrules` - Code assistance for future edits

## 🧪 Testing Your Generated Codebundle

Once the PR is created:

```bash
# 1. Checkout the generated branch
git checkout auto-codebundle-<issue-number>

# 2. Navigate to your codebundle
cd codebundles/azure-network-security-integrity

# 3. Review the files
ls -la
cat README.md

# 4. Test the scripts (set environment variables first)
export AZ_RESOURCE_GROUP="your-resource-group"
export AZURE_RESOURCE_SUBSCRIPTION_ID="your-subscription-id"

# 5. Run individual scripts
./detect_manual_nsg_changes.sh

# 6. Test the Robot Framework tasks
ro runbook.robot
```

## 🔍 Supported Platforms & Examples

### Azure Examples
- **Network Security:** NSG rules, firewalls, network policies
- **Storage:** Storage accounts, blob containers, access policies  
- **Compute:** Virtual machines, scale sets, availability
- **Database:** SQL databases, Cosmos DB, Redis cache

### AWS Examples  
- **Network Security:** Security groups, NACLs, WAF rules
- **Storage:** S3 buckets, EBS volumes, backup policies
- **Compute:** EC2 instances, Auto Scaling groups, Lambda functions
- **Database:** RDS instances, DynamoDB tables, ElastiCache

### Kubernetes Examples
- **Workloads:** Deployments, StatefulSets, DaemonSets
- **Network:** Services, Ingress, Network Policies
- **Storage:** PVCs, Storage Classes, volume mounts
- **Security:** RBAC, Pod Security, service accounts

### GCP Examples
- **Network Security:** Firewall rules, Cloud Armor, VPC policies
- **Storage:** Cloud Storage buckets, persistent disks
- **Compute:** Compute Engine, Cloud Functions, GKE clusters
- **Database:** Cloud SQL, Firestore, Memorystore

## ❗ Troubleshooting

### Generation Fails

**Check these common issues:**

1. **Missing Platform Information**
   ```markdown
   ❌ Bad: "Check the security settings"
   ✅ Good: "Check Azure NSG security settings"
   ```

2. **Vague Task Descriptions**
   ```markdown
   ❌ Bad: "Monitor stuff"
   ✅ Good: "Monitor NSG rule changes and validate against baseline"
   ```

3. **No Clear Tasks**
   ```markdown
   ❌ Bad: Just a title with no task breakdown
   ✅ Good: Numbered list of specific tasks with descriptions
   ```

### Generated Code Issues

**The generated code is a starting point:**

1. **Review and Customize:** Always review the generated scripts
2. **Test Thoroughly:** Test in a safe environment first
3. **Add Error Handling:** Enhance error handling as needed
4. **Update Documentation:** Modify README for your specific use case

### Label Issues

**If labels get stuck:**

1. **Remove Processing Label:** Manually remove `codebundle-processing`
2. **Re-trigger:** Add `auto-generate-codebundle` label again
3. **Check Permissions:** Ensure GitHub Action has proper permissions

## 🎉 Success Tips

### Write Great Issues

1. **Be Specific:** Include exact platform, service, and purpose
2. **Clear Tasks:** Break down exactly what you want the codebundle to do
3. **Add Context:** Include why this codebundle is needed
4. **Use Keywords:** Include relevant technical terms for better detection

### Example of Great Issue Format

```markdown
## Platform: Kubernetes

## Service/Resource Type: Pod Security

## Purpose: Health

## Tasks to Implement:

1. **Pod Security Context Validation**
   - Check that pods are not running as root
   - Validate security context settings
   - Flag pods with privileged access

2. **Network Policy Compliance**
   - Verify network policies are applied to namespaces
   - Check for pods without network restrictions
   - Validate ingress/egress rules

3. **Resource Limit Enforcement**
   - Ensure all pods have resource limits set
   - Check for pods exceeding resource quotas
   - Monitor resource utilization patterns

## Additional Context
This codebundle will be used in our CI/CD pipeline to ensure all deployments meet our security standards before going to production.
```

## 🚀 Ready to Try It?

1. **Create your first issue** using the template or manual format
2. **Add the `auto-generate-codebundle` label**
3. **Watch the action run** in the Actions tab
4. **Review your generated codebundle** in the created PR
5. **Merge and start using** your new codebundle!

The system learns from your existing codebundles, so the more high-quality examples you have, the better the generated code will be.

---

*Need help? Check the [workflow logs](../../actions) or create an issue with the `help` label.*
