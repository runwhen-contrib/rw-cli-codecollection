# 🤖 AI Codebundle Generator - Ready to Use!

## What We Built

Your AI Codebundle Generator is **live and ready** in this repository! It automatically creates complete codebundles from GitHub issues.

## 🚀 How to Use It Right Now

### 1. **Create an Issue**
- Go to **Issues** → **New Issue** → **"Auto-Generate Codebundle"**
- Or create any issue and add the `auto-generate-codebundle` label

### 2. **Fill Out Your Requirements**
```markdown
## Platform: Azure
## Service/Resource Type: Network Security Groups
## Purpose: Integrity
## Tasks to Implement:
1. **Detect Manual NSG Changes**: Compare current rules with desired state
2. **Validate Egress Rules**: Test traffic flow validation
3. **Audit Activity Logs**: Query logs for unauthorized changes
```

### 3. **Watch It Work**
- GitHub Action triggers automatically
- Generates complete codebundle in 2-3 minutes
- Creates pull request with all files

### 4. **Review and Merge**
- Check the generated code
- Test locally if needed
- Merge when ready!

## 📁 Files We Created

### Core Action
- ✅ `.github/workflows/auto-generate-codebundle.yml` - Main workflow
- ✅ `.github/actions/codebundle-generator/` - Custom action with 600+ lines of Python
- ✅ `.github/codebundle-generator-config.yml` - Configuration

### Documentation  
- ✅ `AI_CODEBUNDLE_GENERATOR_USAGE.md` - Complete usage guide
- ✅ `QUICK_START_CODEBUNDLE_GENERATOR.md` - Quick reference
- ✅ `.github/ISSUE_TEMPLATE/auto-generate-codebundle.md` - Issue template

### Testing
- ✅ `.github/actions/codebundle-generator/test_generator.py` - Unit tests (all passing)

## 🎯 What It Generates

For your Azure NSG example, it creates:

```
codebundles/azure-network-security-integrity/
├── detect_manual_nsg_changes.sh           # Compares NSG rules
├── validate_egress_rules.sh               # Tests traffic flow  
├── audit_activity_logs.sh                 # Queries Azure logs
├── runbook.robot                          # Robot Framework tasks
├── meta.yaml                              # Command metadata
├── README.md                              # Complete documentation
└── .cursorrules                           # Code assistance
```

## 🏷️ Label System

| Label | Purpose | Who Applies |
|-------|---------|-------------|
| `auto-generate-codebundle` | Triggers generation | You |
| `codebundle-processing` | Work in progress | System |
| `codebundle-generated` | Success! | System |
| `codebundle-failed` | Error occurred | System |

## 🧪 Test It Now!

**Try this example issue:**

**Title:** `[Auto-Generate] Azure NSG Integrity Tasks`

**Body:**
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

## Additional Context
This addresses the requirements from the original issue about maintaining NSG integrity and detecting unauthorized changes.
```

**Labels:** `auto-generate-codebundle`

## 🎉 Key Features

- ✅ **Smart Platform Detection** - Automatically identifies Azure/AWS/GCP/K8s
- ✅ **Template-Based Generation** - Uses your existing codebundles as patterns
- ✅ **Complete Structure** - Generates scripts, Robot tasks, docs, metadata
- ✅ **Label-Driven Workflow** - Transparent process with clear status
- ✅ **Quality Code** - Follows your established patterns and conventions

## 📚 Documentation

- **Quick Start**: [QUICK_START_CODEBUNDLE_GENERATOR.md](QUICK_START_CODEBUNDLE_GENERATOR.md)
- **Full Guide**: [AI_CODEBUNDLE_GENERATOR_USAGE.md](AI_CODEBUNDLE_GENERATOR_USAGE.md)
- **Issue Template**: [.github/ISSUE_TEMPLATE/auto-generate-codebundle.md](.github/ISSUE_TEMPLATE/auto-generate-codebundle.md)

## 🔧 Configuration

The system is configured via `.github/codebundle-generator-config.yml` and can be customized for:
- Platform detection keywords
- Service type classification  
- Purpose identification
- Label management
- Template preferences

## 🚀 Ready to Use!

The AI Codebundle Generator is **fully functional** and ready for production use. It will:

1. **Save Time** - Generate codebundles in minutes instead of hours
2. **Maintain Quality** - Use your existing patterns as templates
3. **Scale Knowledge** - Make expert practices accessible to everyone
4. **Improve Consistency** - Ensure all codebundles follow established standards

**Go create your first auto-generated codebundle!** 🎉
