#!/usr/bin/env python3
"""
Manual test for the AI Codebundle Generator
Run this to test the generator locally without GitHub Actions
"""

import os
import sys
import tempfile
from pathlib import Path

# Add the current directory to path so we can import main
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from main import CodebundleGenerator

class MockIssue:
    """Mock GitHub issue for testing"""
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

## Additional Context
This is a test issue to validate the AI Codebundle Generator functionality.
"""
        self.number = 999

def test_local_generation():
    """Test the complete generation process locally"""
    print("🧪 Testing AI Codebundle Generator Locally")
    print("=" * 50)
    
    try:
        # Create generator instance
        generator = CodebundleGenerator.__new__(CodebundleGenerator)
        generator.issue = MockIssue()
        
        # Set workspace to repository root (3 levels up from this script)
        script_dir = Path(__file__).parent
        repo_root = script_dir.parent.parent.parent
        generator.workspace_root = repo_root
        
        print(f"📁 Repository root: {repo_root}")
        print(f"📁 Codebundles directory: {repo_root / 'codebundles'}")
        
        # Verify codebundles directory exists
        codebundles_dir = repo_root / 'codebundles'
        if not codebundles_dir.exists():
            print("❌ Codebundles directory not found!")
            return False
        
        print(f"✅ Found {len(list(codebundles_dir.iterdir()))} existing codebundles")
        
        # Test 1: Parse requirements
        print("\n🔍 Step 1: Parsing issue requirements...")
        requirements = generator.parse_issue_requirements()
        print(f"  Platform: {requirements['platform']}")
        print(f"  Service Type: {requirements['service_type']}")
        print(f"  Purpose: {requirements['purpose']}")
        print(f"  Codebundle Name: {requirements['codebundle_name']}")
        print(f"  Tasks: {len(requirements['tasks'])}")
        for i, task in enumerate(requirements['tasks'], 1):
            print(f"    {i}. {task[:60]}...")
        
        # Test 2: Find similar codebundles
        print("\n🔍 Step 2: Finding similar codebundles...")
        similar_bundles = generator.find_similar_codebundles(requirements)
        print(f"  Found {len(similar_bundles)} similar codebundles:")
        for bundle in similar_bundles:
            print(f"    - {bundle}")
        
        # Test 3: Read template files
        print("\n🔍 Step 3: Reading template files...")
        templates = generator.read_template_files(similar_bundles)
        print(f"  Scripts: {len(templates['scripts'])}")
        print(f"  Robot files: {len(templates['robot_tasks'])}")
        print(f"  Meta examples: {len(templates['meta_examples'])}")
        
        # Test 4: Generate scripts
        print("\n🔍 Step 4: Generating bash scripts...")
        scripts = generator.generate_scripts(requirements, templates)
        print(f"  Generated {len(scripts)} scripts:")
        for script_name in scripts.keys():
            print(f"    - {script_name}")
        
        # Test 5: Generate Robot Framework tasks
        print("\n🔍 Step 5: Generating Robot Framework tasks...")
        robot_content = generator.generate_robot_tasks(requirements, templates)
        print(f"  Generated Robot content: {len(robot_content)} characters")
        
        # Test 6: Generate meta.yaml
        print("\n🔍 Step 6: Generating meta.yaml...")
        meta_content = generator.generate_meta_yaml(requirements, scripts)
        print(f"  Generated meta.yaml: {len(meta_content)} characters")
        
        # Test 7: Generate README
        print("\n🔍 Step 7: Generating README.md...")
        readme_content = generator.generate_readme(requirements)
        print(f"  Generated README: {len(readme_content)} characters")
        
        # Test 8: Full generation in temp directory
        print("\n🔍 Step 8: Full generation test...")
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_generator = CodebundleGenerator.__new__(CodebundleGenerator)
            temp_generator.issue = MockIssue()
            temp_generator.workspace_root = Path(temp_dir)
            
            # Create codebundles directory in temp
            (Path(temp_dir) / 'codebundles').mkdir(parents=True)
            
            success = temp_generator.generate_codebundle(requirements, templates)
            
            if success:
                print("  ✅ Full generation successful!")
                
                # List generated files
                codebundle_dir = Path(temp_dir) / 'codebundles' / requirements['codebundle_name']
                if codebundle_dir.exists():
                    print("  📁 Generated files:")
                    for file in sorted(codebundle_dir.iterdir()):
                        size = file.stat().st_size if file.is_file() else 0
                        print(f"    - {file.name} ({size} bytes)")
                        
                        # Show first few lines of each file
                        if file.is_file() and size > 0:
                            try:
                                with open(file, 'r') as f:
                                    first_line = f.readline().strip()
                                    print(f"      → {first_line[:80]}...")
                            except:
                                print("      → (binary or unreadable)")
                else:
                    print("  ❌ Codebundle directory not created")
                    return False
            else:
                print("  ❌ Full generation failed!")
                return False
        
        print("\n🎉 All tests passed successfully!")
        print("\n💡 Next steps:")
        print("  1. Push your branch: git push origin HEAD")
        print("  2. Create a test issue with the auto-generate-codebundle label")
        print("  3. Watch the GitHub Action run on your branch")
        
        return True
        
    except Exception as e:
        print(f"\n❌ Test failed with error: {e}")
        import traceback
        traceback.print_exc()
        return False

def test_specific_components():
    """Test individual components"""
    print("\n🔧 Testing Individual Components")
    print("=" * 50)
    
    try:
        # Test issue parsing only
        generator = CodebundleGenerator.__new__(CodebundleGenerator)
        generator.issue = MockIssue()
        
        requirements = generator.parse_issue_requirements()
        
        print("✅ Issue parsing works")
        print(f"  Detected platform: {requirements['platform']}")
        print(f"  Detected service: {requirements['service_type']}")
        print(f"  Detected purpose: {requirements['purpose']}")
        
        # Test script name generation
        script_names = []
        for task in requirements['tasks']:
            script_name = generator._task_to_script_name(task)
            script_names.append(script_name)
        
        print("✅ Script name generation works")
        print("  Generated script names:")
        for name in script_names:
            print(f"    - {name}")
        
        return True
        
    except Exception as e:
        print(f"❌ Component test failed: {e}")
        return False

if __name__ == "__main__":
    print("🚀 AI Codebundle Generator - Manual Test")
    print("This will test the generator locally without GitHub Actions")
    print()
    
    # Run component tests first
    if test_specific_components():
        print()
        # Run full test
        success = test_local_generation()
        
        if success:
            print("\n🎉 Ready for GitHub Actions testing!")
        else:
            print("\n❌ Fix issues before testing on GitHub")
            sys.exit(1)
    else:
        print("\n❌ Component tests failed")
        sys.exit(1)
