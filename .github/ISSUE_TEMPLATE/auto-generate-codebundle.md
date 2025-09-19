---
name: Auto-Generate Codebundle
about: Request automatic generation of a new codebundle using AI
title: "[Auto-Generate] "
labels: ["auto-generate-codebundle"]
assignees: ''
---

## 🤖 Auto-Generate Codebundle Request

**Platform** (Azure/AWS/GCP/Kubernetes):
<!-- e.g., Azure -->

**Service/Resource Type**:
<!-- e.g., Network Security Groups, Firewalls, Storage Accounts -->

**Purpose** (Health/Triage/Integrity/Ops):
<!-- e.g., Integrity checking, Health monitoring -->

## Tasks to Implement

Please describe the specific tasks this codebundle should perform:

1. **Task 1**: <!-- e.g., Detect Manual NSG Changes -->
   - Compare current NSG rules with repo-managed desired state
   - Flag discrepancies that indicate out-of-band changes

2. **Task 2**: <!-- e.g., Subnet Egress Validation -->
   - Confirm traffic flow from each subnet by testing NSG and VNet rule enforcement

3. **Task 3**: <!-- e.g., Log Activity Audit for NSG/Firewall Changes -->
   - Query activity logs to identify whether firewall/NSG changes were pushed through CI/CD pipeline vs. manual actors

## Additional Context

<!-- Any additional information that would help generate the codebundle -->

---

### 🚀 How This Works

1. 🏷️ **Label Applied**: This issue has the `auto-generate-codebundle` label
2. 🤖 **AI Processing**: GitHub Action parses your requirements and finds similar codebundles as templates
3. 📝 **Code Generation**: Creates bash scripts, Robot Framework tasks, and documentation
4. 🔄 **PR Created**: A pull request is created with the complete codebundle
5. ✅ **Review & Merge**: Review the generated code and merge when ready

### 📦 Expected Output

The system will generate a complete codebundle:

```
codebundles/your-platform-service-purpose/
├── task_script_1.sh              # Bash scripts for each task
├── task_script_2.sh              # Platform-specific implementations
├── runbook.robot                 # Robot Framework task definitions
├── meta.yaml                     # Command metadata & documentation
├── README.md                     # Usage instructions
└── .cursorrules                  # Code assistance rules
```

### 🏷️ Label Workflow

- `auto-generate-codebundle` → **Triggers** the generation
- `codebundle-processing` → **In progress** (applied automatically)
- `codebundle-generated` → **Success** (applied automatically)
- `codebundle-failed` → **Failed** (applied automatically)

### 💡 Tips for Better Results

- **Be Specific**: Include exact platform and service names
- **Clear Tasks**: Break down what you want each task to do
- **Use Keywords**: Include technical terms (NSG, VPC, kubectl, etc.)
- **Add Context**: Explain why this codebundle is needed

### 📚 Examples

**Azure NSG Integrity:**
```markdown
## Platform: Azure
## Service: Network Security Groups  
## Purpose: Integrity
## Tasks:
1. Detect manual NSG rule changes
2. Validate subnet egress rules
3. Audit firewall configuration changes
```

**Kubernetes Pod Health:**
```markdown
## Platform: Kubernetes
## Service: Pods
## Purpose: Health  
## Tasks:
1. Check pod resource utilization
2. Validate pod networking
3. Monitor restart patterns
```

