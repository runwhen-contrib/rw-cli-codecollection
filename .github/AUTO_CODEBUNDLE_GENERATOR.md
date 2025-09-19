# 🤖 Auto Codebundle Generator

The Auto Codebundle Generator is a GitHub Action that automatically creates complete codebundles from GitHub issues using AI and existing templates.

## How It Works

### 1. **Issue Creation**
- Create a new issue using the "Auto-Generate Codebundle" template
- Or add the `auto-generate-codebundle` label to any existing issue
- Describe your requirements in the issue body

### 2. **Automatic Processing**
- GitHub Action triggers when the label is applied
- AI parses your requirements and extracts:
  - Platform (Azure/AWS/GCP/Kubernetes)
  - Service type (network, storage, compute, etc.)
  - Purpose (health, triage, integrity, ops)
  - Specific tasks to implement

### 3. **Template Analysis**
- System finds similar existing codebundles
- Analyzes their structure and patterns
- Uses them as templates for generation

### 4. **Code Generation**
- Generates bash scripts for each task
- Creates Robot Framework task definitions
- Builds complete documentation
- Follows established coding patterns

### 5. **Pull Request Creation**
- Creates a PR with the generated codebundle
- Links back to the original issue
- Includes review checklist and instructions

## Label Workflow

| Label | Purpose | When Applied |
|-------|---------|--------------|
| `auto-generate-codebundle` | Triggers generation | Manual (user) |
| `codebundle-processing` | Indicates work in progress | Auto (during processing) |
| `codebundle-generated` | Generation successful | Auto (on success) |
| `codebundle-failed` | Generation failed | Auto (on failure) |
| `awaiting-review` | Ready for human review | Auto (on success) |

## Example Issue Format

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

## Generated Output

For the above example, the system would generate:

```
codebundles/azure-network-security-integrity/
├── detect_manual_nsg_changes.sh
├── subnet_egress_validation.sh  
├── log_activity_audit_for_nsg_firewall_changes.sh
├── runbook.robot
├── meta.yaml
├── README.md
└── .cursorrules
```

## Configuration

The system is configured via `.github/codebundle-generator-config.yml`:

- **Platform Detection**: Keywords that identify different platforms
- **Service Type Mapping**: How to categorize different services
- **Purpose Classification**: Different types of codebundle purposes
- **Label Management**: Which labels to use for workflow states

## Requirements

### Repository Secrets

- `OPENAI_API_KEY` (optional): For enhanced AI generation
- `GITHUB_TOKEN`: Automatically provided by GitHub Actions

### Permissions

The GitHub Action needs:
- `contents: write` - To create files and commits
- `pull-requests: write` - To create pull requests  
- `issues: write` - To manage issue labels and comments

## Customization

### Adding New Platforms

Edit `.github/codebundle-generator-config.yml`:

```yaml
platforms:
  your_platform:
    keywords: ["keyword1", "keyword2"]
    cli: "your-cli-command"
```

### Modifying Templates

The system automatically uses existing codebundles as templates. To improve generation:

1. Ensure your existing codebundles follow consistent patterns
2. Add good examples for each platform/service combination
3. Use clear, descriptive script and task names

### Adjusting AI Behavior

Modify the prompts in `.github/actions/codebundle-generator/main.py`:

- `parse_issue_requirements()` - How requirements are extracted
- `generate_scripts()` - How bash scripts are generated  
- `generate_robot_tasks()` - How Robot Framework tasks are created

## Troubleshooting

### Generation Fails

1. Check the [workflow logs](../../actions) for detailed error messages
2. Ensure your issue has clear, structured requirements
3. Verify the platform/service type is supported
4. Check that similar codebundles exist as templates

### Generated Code Issues

1. The generated code is a starting point - review and customize as needed
2. Test locally before merging
3. Update documentation if you make significant changes
4. Consider contributing improvements back to the generator

### Label Management

If labels get stuck in the wrong state:

1. Manually remove processing labels
2. Re-apply the trigger label to retry
3. Check repository permissions for the GitHub Action

## Contributing

To improve the Auto Codebundle Generator:

1. **Add Better Templates**: Create high-quality codebundles that can serve as templates
2. **Improve Detection**: Enhance keyword matching in the config file
3. **Extend Platforms**: Add support for new platforms or services
4. **Enhance AI Prompts**: Improve the generation logic in the Python script

## Support

For issues with the Auto Codebundle Generator:

1. Check existing issues with the `codebundle-generator` label
2. Create a new issue with detailed error information
3. Include the original issue that failed to generate
4. Attach relevant workflow logs

