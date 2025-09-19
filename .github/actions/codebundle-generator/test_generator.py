#!/usr/bin/env python3
"""
Test script for the codebundle generator
"""

import os
import tempfile
import shutil
from pathlib import Path
from main import CodebundleGenerator

def test_issue_parsing():
    """Test issue requirement parsing"""
    
    # Mock issue data
    class MockIssue:
        def __init__(self):
            self.title = "Azure Firewall & NSG Integrity Tasks"
            self.body = """
            ## Platform: Azure
            
            ## Tasks to Implement:
            
            1. **Detect Manual NSG Changes**
               - Compare current NSG rules with repo-managed desired state
               - Flag discrepancies that indicate out-of-band changes
            
            2. **Subnet Egress Validation**
               - Confirm traffic flow from each subnet by testing NSG and VNet rule enforcement
            
            3. **Log Activity Audit for NSG/Firewall Changes**
               - Query activity logs to identify whether firewall/NSG changes were pushed through CI/CD pipeline vs. manual actors
            """
            self.number = 49
    
    # Create a temporary generator instance
    generator = CodebundleGenerator.__new__(CodebundleGenerator)
    generator.issue = MockIssue()
    
    # Test requirement parsing
    requirements = generator.parse_issue_requirements()
    
    print("✅ Issue Parsing Test")
    print(f"Platform: {requirements['platform']}")
    print(f"Service Type: {requirements['service_type']}")
    print(f"Purpose: {requirements['purpose']}")
    print(f"Codebundle Name: {requirements['codebundle_name']}")
    print(f"Tasks: {len(requirements['tasks'])}")
    
    # Validate results
    assert requirements['platform'] == 'azure'
    assert 'network' in requirements['service_type']
    assert requirements['purpose'] == 'integrity'
    assert len(requirements['tasks']) >= 3
    
    print("✅ All assertions passed!\n")

def test_script_generation():
    """Test bash script generation"""
    
    # Mock requirements
    requirements = {
        'platform': 'azure',
        'service_type': 'network-security',
        'purpose': 'integrity',
        'codebundle_name': 'azure-network-security-integrity',
        'tasks': [
            'Detect Manual NSG Changes',
            'Subnet Egress Validation'
        ]
    }
    
    # Mock templates
    templates = {
        'scripts': [{
            'name': 'test.sh',
            'content': '''#!/bin/bash
# Test template
issues_json='{"issues": []}'
# TODO: Add specific task logic here
echo "$issues_json" > "$OUTPUT_DIR/results.json"
''',
            'bundle': 'test-bundle'
        }]
    }
    
    # Create generator instance
    generator = CodebundleGenerator.__new__(CodebundleGenerator)
    
    # Test script generation
    scripts = generator.generate_scripts(requirements, templates)
    
    print("✅ Script Generation Test")
    print(f"Generated {len(scripts)} scripts:")
    for script_name in scripts.keys():
        print(f"  - {script_name}")
    
    # Validate results
    assert len(scripts) == 2
    assert 'detect_manual_nsg_changes.sh' in scripts
    assert 'subnet_egress_validation.sh' in scripts
    
    # Check script content
    nsg_script = scripts['detect_manual_nsg_changes.sh']
    assert '#!/bin/bash' in nsg_script
    assert 'NSG' in nsg_script or 'Network Security' in nsg_script
    
    print("✅ All assertions passed!\n")

def test_robot_generation():
    """Test Robot Framework task generation"""
    
    requirements = {
        'platform': 'azure',
        'service_type': 'network-security', 
        'purpose': 'integrity',
        'codebundle_name': 'azure-network-security-integrity',
        'tasks': ['Detect Manual NSG Changes'],
        'title': 'Test Codebundle',
        'issue_number': 49
    }
    
    templates = {'robot_tasks': []}
    
    generator = CodebundleGenerator.__new__(CodebundleGenerator)
    robot_content = generator.generate_robot_tasks(requirements, templates)
    
    print("✅ Robot Framework Generation Test")
    print("Generated Robot Framework content:")
    print(f"Length: {len(robot_content)} characters")
    
    # Validate content
    assert '*** Settings ***' in robot_content
    assert '*** Tasks ***' in robot_content
    assert 'Detect Manual NSG Changes' in robot_content
    assert 'Library             RW.Core' in robot_content
    
    print("✅ All assertions passed!\n")

def main():
    """Run all tests"""
    print("🧪 Testing Codebundle Generator\n")
    
    try:
        test_issue_parsing()
        test_script_generation()
        test_robot_generation()
        
        print("🎉 All tests passed successfully!")
        
    except Exception as e:
        print(f"❌ Test failed: {e}")
        return 1
    
    return 0

if __name__ == "__main__":
    exit(main())

