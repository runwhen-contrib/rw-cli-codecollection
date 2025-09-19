# 🚀 Quick Start: AI Codebundle Generator

## TL;DR - Get a Codebundle in 3 Steps

1. **Create Issue** → Use template or add `auto-generate-codebundle` label
2. **Wait 2-3 minutes** → GitHub Action generates complete codebundle  
3. **Review PR** → Merge when ready!

## 📝 Issue Format (Copy & Paste)

```markdown
## Platform: [Azure|AWS|GCP|Kubernetes]

## Service/Resource Type: [Network Security Groups|Storage|Compute|etc.]

## Purpose: [Health|Triage|Integrity|Ops]

## Tasks to Implement:

1. **Task Name**: What this task should do
2. **Another Task**: Another description
3. **Third Task**: Yet another description
```

## 🎯 Real Examples

### Azure NSG Integrity
```markdown
## Platform: Azure
## Service/Resource Type: Network Security Groups  
## Purpose: Integrity
## Tasks to Implement:
1. **Detect Manual Changes**: Compare NSG rules with IaC definitions
2. **Validate Egress Rules**: Test actual traffic flow vs expected rules
3. **Audit Log Analysis**: Query activity logs for unauthorized changes
```
**→ Generates:** `azure-network-security-integrity/`

### Kubernetes Pod Health  
```markdown
## Platform: Kubernetes
## Service/Resource Type: Pods
## Purpose: Health
## Tasks to Implement:
1. **Resource Utilization**: Check CPU/memory usage against limits
2. **Network Connectivity**: Validate pod-to-pod and external connectivity
3. **Restart Analysis**: Monitor and analyze pod restart patterns
```
**→ Generates:** `k8s-pods-health/`

### AWS S3 Security
```markdown
## Platform: AWS
## Service/Resource Type: S3 Buckets
## Purpose: Integrity  
## Tasks to Implement:
1. **Bucket Policy Validation**: Check policies against security baselines
2. **Public Access Detection**: Identify buckets with public access
3. **Encryption Compliance**: Verify encryption settings and key management
```
**→ Generates:** `aws-s3-buckets-integrity/`

## 🏷️ Labels You'll See

| Label | What It Means |
|-------|---------------|
| `auto-generate-codebundle` | **You add this** - triggers generation |
| `codebundle-processing` | **System adds** - generation in progress |
| `codebundle-generated` | **System adds** - success! PR created |
| `codebundle-failed` | **System adds** - something went wrong |

## 📦 What You Get

Every generated codebundle includes:

```
codebundles/your-codebundle-name/
├── script1.sh          # Bash scripts for each task
├── script2.sh          # Platform-specific implementations  
├── script3.sh          # Proper error handling included
├── runbook.robot       # Complete Robot Framework tasks
├── meta.yaml          # Command definitions & docs
├── README.md          # Usage instructions
└── .cursorrules       # Code assistance
```

## ⚡ Pro Tips

### Make It Work Better
- **Use specific terms**: "NSG rules" not "network stuff"
- **Include platform keywords**: Azure, kubectl, aws cli, etc.
- **Be clear about tasks**: What exactly should each script do?

### Keywords That Help
- **Azure**: `az`, `nsg`, `vnet`, `resource group`, `subscription`
- **AWS**: `aws`, `vpc`, `security group`, `s3`, `ec2`, `lambda`  
- **Kubernetes**: `kubectl`, `pod`, `deployment`, `namespace`, `service`
- **GCP**: `gcloud`, `gke`, `gcs`, `compute engine`

## 🧪 Test Your Codebundle

```bash
# 1. Checkout the generated branch
git checkout auto-codebundle-123

# 2. Go to your codebundle  
cd codebundles/your-codebundle-name

# 3. Check what was generated
ls -la
cat README.md

# 4. Test it (set environment variables first)
export AZ_RESOURCE_GROUP="test-rg"  # for Azure
export CONTEXT="test-cluster"       # for Kubernetes
export AWS_REGION="us-west-2"       # for AWS

# 5. Run the scripts
./your_script.sh

# 6. Test Robot Framework
ro runbook.robot
```

## ❗ Troubleshooting

### Generation Failed?
1. **Check the issue format** - include platform, service, tasks
2. **Be more specific** - "Azure NSG rules" not "network security"  
3. **Add more context** - explain what the codebundle should do
4. **Check the logs** - go to Actions tab for error details

### Generated Code Not Perfect?
**That's normal!** The generated code is a starting point:
- Review and customize the scripts
- Add your specific logic and error handling
- Update environment variables for your setup
- Modify documentation as needed

## 🎉 Ready to Try?

1. **Go to Issues** → **New Issue**
2. **Select "Auto-Generate Codebundle"** template  
3. **Fill it out** with your requirements
4. **Submit** and watch the magic happen!

Or just create any issue and add the `auto-generate-codebundle` label.

---

**Need the full guide?** See [AI_CODEBUNDLE_GENERATOR_USAGE.md](AI_CODEBUNDLE_GENERATOR_USAGE.md)
