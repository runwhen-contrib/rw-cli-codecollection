#!/usr/bin/env python3
"""Simple runner to execute pytest-based tests without pytest command."""

import sys
import os

# Add the java directory to path and set up proper package structure
java_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

sys.path.insert(0, os.path.dirname(java_dir))

# Import as if running from the parent directory of java
from java.tests.test_fetch_tracebacks import TestJavaTracebackExtractor


def run_tests():
    """Run the tests without pytest."""
    from java.fetch_tracebacks import JavaTracebackExtractor
    import json

    test_instance = TestJavaTracebackExtractor()

    # Create instances directly instead of using pytest fixtures
    extractor = JavaTracebackExtractor()

    # Load test cases directly
    test_file_path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        'test-cases',
        'has_timestamp_at_alphanumeric_start.json'
    )
    with open(test_file_path, 'r') as f:
        test_cases = json.load(f)['test_cases']

    try:
        # Run the test method
        test_instance.test_has_timestamp_at_alphanumeric_start(extractor, test_cases)
        print("✓ All tests passed!")
        return True
    except AssertionError as e:
        print(f"✗ Test failed: {e}")
        return False
    except Exception as e:
        print(f"✗ Error running tests: {e}")
        return False


if __name__ == "__main__":
    print(f"java_dir = {java_dir}\n")
    success = run_tests()
    sys.exit(0 if success else 1)