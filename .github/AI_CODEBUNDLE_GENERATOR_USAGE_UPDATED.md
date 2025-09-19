# 🤖 AI Codebundle Generator - Usage Guide

## How to Use

### Method 1: Automatic Trigger (Labels)

Create an issue with **both** labels:
- Any label containing `new` (e.g., `new-codebundle-request`, `new-feature`)  
- Any label containing `auto-intake` (e.g., `auto-intake`, `auto-intake-ready`)

**Example labels that work:**
- `new-codebundle-request` + `auto-intake`
- `new` + `auto-intake-ready`
- `codebundle-new` + `auto-intake`

### Method 2: Manual Execution

1. Go to **Actions** tab
2. Select **"Auto-Generate Codebundle from Issue"**
3. Click **"Run workflow"**
4. Enter the issue number
5. Click **"Run workflow"**

## Issue Format

```markdown
## Platform: [Azure|AWS|GCP|Kubernetes]

## Service/Resource Type: [Network Security Groups|Storage|etc.]

## Purpose: [Health|Triage|Integrity|Ops]

## Tasks to Implement:

1. **Task Name**: Description of what this should do
2. **Another Task**: Another description
```

## Label Workflow

| Phase | Labels | Description |
|-------|--------|-------------|
| **Trigger** | `new` + `auto-intake` | Starts the process |
| **Processing** | `codebundle-processing` | Generation in progress |
| **Success** | `codebundle-generated` + `pr-created` | PR created successfully |
| **Failure** | `codebundle-failed` | Something went wrong |

## What Happens

1. **Labels Detected** → Workflow triggers automatically
2. **Trigger Labels Removed** → `new` and `auto-intake` labels are removed
3. **Processing Starts** → `codebundle-processing` label added
4. **Code Generated** → Uses local `.github/actions/codebundle-generator`
5. **PR Created** → Complete codebundle in new pull request
6. **Success Labels** → `codebundle-generated` + `pr-created` added
7. **Issue Comment** → Bot comments with PR link and next steps

## Example Usage

### Create Issue
**Title:** `Azure NSG Integrity Monitoring`

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
```

**Labels:** `new-codebundle-request` + `auto-intake`

### Result
- Generates: `codebundles/azure-network-security-integrity/`
- Creates PR with complete codebundle
- Issue gets `codebundle-generated` + `pr-created` labels
- Bot comments with PR link

## Manual Testing

To test manually:

1. **Create any issue** (doesn't need special format for testing)
2. **Go to Actions** → **"Auto-Generate Codebundle from Issue"**
3. **Run workflow** with the issue number
4. **Watch it generate** the codebundle

## Configuration

The system uses:
- **Action**: `.github/actions/codebundle-generator/` (local)
- **Config**: `.github/codebundle-generator-config.yml`
- **Templates**: Existing codebundles in `codebundles/`

## Ready to Use!

The workflow is now configured to:
- ✅ Use the local action (no external dependencies)
- ✅ Support manual execution via workflow_dispatch
- ✅ Look for `new` + `auto-intake` labels
- ✅ Remove trigger labels when processing starts
- ✅ Add appropriate status labels throughout the process
- ✅ Create PRs that auto-close the original issue

**Try it now!** Create an issue with the right labels or run it manually from the Actions tab.
