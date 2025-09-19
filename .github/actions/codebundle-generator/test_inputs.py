#!/usr/bin/env python3
"""
Test script to debug action inputs
"""

import os
import sys

def test_inputs():
    """Test if action inputs are available"""
    print("=== TESTING ACTION INPUTS ===")
    
    # Check all environment variables
    print("\nAll environment variables starting with INPUT_:")
    input_vars = {k: v for k, v in os.environ.items() if k.startswith('INPUT_')}
    
    if not input_vars:
        print("❌ No INPUT_ environment variables found!")
        print("\nAll environment variables:")
        for k, v in sorted(os.environ.items()):
            print(f"  {k}: {v[:50]}..." if len(v) > 50 else f"  {k}: {v}")
    else:
        print("✅ Found INPUT_ environment variables:")
        for k, v in input_vars.items():
            # Mask sensitive values
            display_value = v if k != 'INPUT_OPENAI_API_KEY' else ('***' + v[-4:] if v else 'NOT_SET')
            print(f"  {k}: {display_value}")
    
    # Test required inputs
    print("\n=== TESTING REQUIRED INPUTS ===")
    
    try:
        issue_number = os.environ['INPUT_ISSUE_NUMBER']
        print(f"✅ Issue number: {issue_number}")
    except KeyError:
        print("❌ INPUT_ISSUE_NUMBER not found")
    
    try:
        github_token = os.environ['INPUT_GITHUB_TOKEN']
        print(f"✅ GitHub token: {'***' + github_token[-4:] if github_token else 'NOT_SET'}")
    except KeyError:
        print("❌ INPUT_GITHUB_TOKEN not found")
    
    openai_key = os.environ.get('INPUT_OPENAI_API_KEY', '')
    if openai_key:
        print(f"✅ OpenAI API key: {'***' + openai_key[-4:] if openai_key else 'NOT_SET'}")
    else:
        print("⚠️  OpenAI API key not provided (will use template generation)")
    
    print("\n=== TEST COMPLETE ===")

if __name__ == "__main__":
    test_inputs()
