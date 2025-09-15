import json
import pytest
import os
from ..fetch_tracebacks import JavaTracebackExtractor


class TestJavaTracebackExtractor:
    """Test cases for JavaTracebackExtractor methods."""

    @pytest.fixture
    def extractor(self):
        """Create a JavaTracebackExtractor instance for testing."""
        return JavaTracebackExtractor()

    @pytest.fixture
    def timestamp_test_cases(self):
        """Load test cases from JSON file."""
        test_file_path = os.path.join(
            os.path.dirname(__file__),
            'test-cases',
            'has_timestamp_at_alphanumeric_start.json'
        )
        with open(test_file_path, 'r') as f:
            return json.load(f)['test_cases']

    def test_has_timestamp_at_alphanumeric_start(self, extractor, timestamp_test_cases):
        """Test _has_timestamp_at_alphanumeric_start method with various inputs."""
        for test_case in timestamp_test_cases:
            result = extractor._has_timestamp_at_alphanumeric_start(test_case['input'])
            assert result == test_case['expected'], (
                f"Test '{test_case['name']}' failed: "
                f"Expected {test_case['expected']}, got {result} "
                f"for input: '{test_case['input']}'"
            )