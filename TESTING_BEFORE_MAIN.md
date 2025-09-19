# 🧪 Testing AI Codebundle Generator Before Main

Since the GitHub Action workflow isn't on `main` yet, here are several ways to test it:

## Method 1: Test Locally (Recommended)

### Run the Python Script Directly

```bash
# 1. Navigate to the action directory
cd .github/actions/codebundle-generator

# 2. Install dependencies (if not already done)
pip install PyGithub pyyaml jinja2

# 3. Run the existing tests
python test_generator.py

# 4. Test with a mock issue (create test_manual.py)
```

Let me create a manual test script for you:

### Create Manual Test Script

```python
# test_manual.py - Test the generator with mock data
import os
import tempfile
from pathlib import Path
from main import CodebundleGenerator

# Mock issue data for testing
class MockIssue:
    def __init__(self):
        self.title = "Azure Firewall & NSG Integrity Tasks"
        self.body = """
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
        """
        self.number = 999

# Create temporary test
def test_local_generation():
    print("🧪 Testing AI Codebundle Generator Locally")
    
    # Create generator with mock data
    generator = CodebundleGenerator.__new__(CodebundleGenerator)
    generator.issue = MockIssue()
    generator.workspace_root = Path.cwd().parent.parent.parent  # Go back to repo root
    
    # Test parsing
    requirements = generator.parse_issue_requirements()
    print(f"✅ Parsed requirements: {requirements['codebundle_name']}")
    
    # Test template finding
    similar_bundles = generator.find_similar_codebundles(requirements)
    print(f"✅ Found {len(similar_bundles)} similar codebundles")
    
    # Test template reading
    templates = generator.read_template_files(similar_bundles)
    print(f"✅ Read templates: {len(templates['scripts'])} scripts, {len(templates['robot_tasks'])} robot files")
    
    # Test generation (in temp directory)
    with tempfile.TemporaryDirectory() as temp_dir:
        generator.workspace_root = Path(temp_dir)
        success = generator.generate_codebundle(requirements, templates)
        
        if success:
            print("✅ Generation successful!")
            # List generated files
            codebundle_dir = Path(temp_dir) / 'codebundles' / requirements['codebundle_name']
            if codebundle_dir.exists():
                print("📁 Generated files:")
                for file in codebundle_dir.iterdir():
                    print(f"  - {file.name}")
        else:
            print("❌ Generation failed!")

if __name__ == "__main__":
    test_local_generation()
```

## Method 2: Test on Feature Branch

### Push Your Branch and Test There

```bash
# 1. Push your current branch
git add .
git commit -m "feat: add AI codebundle generator"
git push origin your-branch-name

# 2. Create a test issue on GitHub
# 3. Add the auto-generate-codebundle label
# 4. The workflow will run on your branch!
```

**Note**: The workflow will trigger on your branch because it's defined in `.github/workflows/` and GitHub Actions run workflows from the branch where the triggering event occurs.

## Method 3: Use GitHub's Workflow Dispatch

### Add Manual Trigger to Workflow

Add this to your workflow file:

```yaml
on:
  issues:
    types: [opened, labeled]
  workflow_dispatch:  # Add this line
    inputs:
      issue_number:
        description: 'Issue number to test with'
        required: true
        type: number
```

Then you can manually trigger it from the Actions tab.

## Method 4: Test Individual Components

### Test the Issue Parser

```bash
cd .github/actions/codebundle-generator

# Create a simple test
python3 -c "
from main import CodebundleGenerator

class MockIssue:
    title = 'Azure NSG Integrity Tasks'
    body = '''
## Platform: Azure
## Service: Network Security Groups  
## Purpose: Integrity
## Tasks:
1. Detect manual changes
2. Validate rules
'''
    number = 123

gen = CodebundleGenerator.__new__(CodebundleGenerator)
gen.issue = MockIssue()
req = gen.parse_issue_requirements()
print('Codebundle name:', req['codebundle_name'])
print('Platform:', req['platform'])
print('Tasks:', len(req['tasks']))
"
```

### Test Template Finding

```bash
# Test finding similar codebundles
python3 -c "
import sys
sys.path.append('/home/runwhen/codecollection')
from pathlib import Path
import os
os.chdir('/home/runwhen/codecollection')

# Your test code here
print('Current directory:', Path.cwd())
print('Codebundles exist:', (Path.cwd() / 'codebundles').exists())
if (Path.cwd() / 'codebundles').exists():
    bundles = list((Path.cwd() / 'codebundles').iterdir())
    azure_bundles = [b.name for b in bundles if b.name.startswith('azure')]
    print('Azure codebundles:', azure_bundles[:5])
"
```

## Method 5: Create Test Issue Right Now

Since you're on a feature branch, you can actually test it right now:

### Step 1: Push Your Branch
```bash
git add .
git commit -m "feat: AI codebundle generator ready for testing"
git push origin HEAD
```

### Step 2: Create Test Issue

Go to GitHub Issues and create:

**Title**: `[TEST] Azure NSG Integrity - AI Generator Test`

**Body**:
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
This is a test of the AI Codebundle Generator system before merging to main.
```

**Labels**: `auto-generate-codebundle`

### Step 3: Watch It Work!

The GitHub Action will run on your branch and create a PR with the generated codebundle.

## Quick Local Test Right Now

Let me create a simple test you can run immediately:
