"""
Java Stacktrace Extraction Module

This module provides functionality to extract Java stacktraces from log files.
It handles various log formats and can identify stacktrace patterns even when
logs are split across multiple lines or contain timestamps.

Key Features:
- Extracts Java stacktraces from log entries
- Handles multiple timestamp formats (DD-MM-YYYY and ISO 8601)
- Reconstructs multi-line log entries that may have been split
- Filters logs to find those containing stacktrace information
- Supports both complete stacktraces (with exceptions) and standalone stacktrace frames

Usage:
    extractor = JavaTracebackExtractor()
    stacktraces = extractor.extract_tracebacks_from_logs(log_lines)

Author: RW CLI Code Collection
"""

import re

# List of timestamp patterns to handle
TIMESTAMP_PATTERNS = [
    r'^\d{2}-\d{2}-\d{4}\s\d{2}:\d{2}:\d{2}\.\d{3}',  # DD-MM-YYYY HH:MM:SS.mmm
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z?'    # ISO 8601: YYYY-MM-DDTHH:MM:SS.nnnnnnnZ
]
# JAVA_PATTERN = re.compile(r'^\s*at\s+[a-zA-Z_][\w$]*(\.[a-zA-Z_][\w$]*)+')
JAVA_PATTERN = re.compile(r'\s+at\s+[a-zA-Z_][\w$]*(\.[a-zA-Z_][\w$]*)+\([^)]*\)')


class JavaTracebackExtractor:
    def matches_any_timestamp_pattern(self, text):
        """
        Check if text matches any of the supported timestamp patterns.
        
        This method validates whether the provided text starts with a recognized
        timestamp format. It supports two common timestamp patterns:
        - DD-MM-YYYY HH:MM:SS.mmm format
        - ISO 8601 format (YYYY-MM-DDTHH:MM:SS.nnnnnnnZ)
        
        Args:
            text (str): The text to check for timestamp patterns
            
        Returns:
            bool: True if the text matches any supported timestamp pattern, False otherwise
            
        Example:
            >>> extractor = JavaTracebackExtractor()
            >>> extractor.matches_any_timestamp_pattern("2024-01-15T10:30:45.123Z")
            True
            >>> extractor.matches_any_timestamp_pattern("15-01-2024 10:30:45.123")
            True
            >>> extractor.matches_any_timestamp_pattern("INFO: Application started")
            False
        """
        if not text.strip():
            return False
        
        for pattern in TIMESTAMP_PATTERNS:
            if re.match(pattern, text.strip()):
                return True
        return False

    def has_timestamp_at_alphanumeric_start(self, line):
        """
        Check if there's a timestamp pattern starting from the first alphanumeric character.
        
        This method is used to identify the start of new log entries versus continuation
        lines. It finds the first alphanumeric character in the line and checks if
        a timestamp pattern exists from that position. If no timestamp is found from
        the first alphanumeric position, the line is likely a continuation of the
        previous log entry.
        
        Args:
            line (str): The log line to analyze
            
        Returns:
            bool: True if a timestamp pattern is found starting from the first
                  alphanumeric character, False otherwise
                  
        Example:
            >>> extractor = JavaTracebackExtractor()
            >>> extractor.has_timestamp_at_alphanumeric_start("2024-01-15T10:30:45.123Z INFO: Application started")
            True
            >>> extractor.has_timestamp_at_alphanumeric_start("    at com.example.Class.method(Class.java:123)")
            False
            >>> extractor.has_timestamp_at_alphanumeric_start("   Caused by: java.lang.NullPointerException")
            False
        """
        if not line.strip():
            return False
        
        # Find the first alphanumeric character
        first_alnum_pos = None
        for i, char in enumerate(line):
            if char.isalnum():
                first_alnum_pos = i
                break
        
        if first_alnum_pos is None:
            return False
        
        # Check if timestamp pattern exists from that position
        remaining_line = line[first_alnum_pos:]
        return self.matches_any_timestamp_pattern(remaining_line)

    def line_starts_with_at(self, log_line: str) -> bool:
        """
        Check if a log line contains Java stacktrace frame information.
        
        This method uses a regex pattern to identify lines that contain
        Java stacktrace frames, which typically start with whitespace
        followed by "at" and contain method signatures.
        
        Args:
            log_line (str): The log line to check for stacktrace frame patterns
            
        Returns:
            bool: True if the line contains a Java stacktrace frame, False otherwise
            
        Example:
            >>> extractor = JavaTracebackExtractor()
            >>> extractor.line_starts_with_at("    at com.example.Class.method(Class.java:123)")
            True
            >>> extractor.line_starts_with_at("INFO: Application started")
            False
        """
        return JAVA_PATTERN.search(log_line) is not None

    def filter_logs_having_trace(self, logs: list[str]) -> list[str]:
        """
        Filter logs to extract only those containing Java stacktrace information.
        
        This method analyzes each log entry to determine if it contains
        Java stacktrace frames. It looks for two types of stacktrace content:
        1. Complete stacktraces: logs containing both "exception" keyword and stacktrace frames
        2. Standalone stacktrace frames: logs containing at least one stacktrace frame
        
        Args:
            logs (list[str]): List of log entries to filter
            
        Returns:
            list[str]: List of log entries that contain stacktrace information
            
        Note:
            The method handles multi-line log entries by splitting on newlines
            and checking each line for stacktrace patterns.
            
        Example:
            >>> extractor = JavaTracebackExtractor()
            >>> logs = [
            ...     "INFO: Application started",
            ...     "Exception in thread main: java.lang.NullPointerException\n    at com.example.Class.method(Class.java:123)"
            ... ]
            >>> extractor.filter_logs_having_trace(logs)
            ['Exception in thread main: java.lang.NullPointerException\n    at com.example.Class.method(Class.java:123)']
        """
        stacktraces = []
        for line in logs:
            nested_logs = line.split("\n")
            
            # Check if this log contains stacktrace frames
            at_lines = [nested_log for nested_log in nested_logs if self.line_starts_with_at(nested_log)]
            
            if "exception" in line.lower() and at_lines:
                # Complete stacktrace: has exception + stacktrace frames
                stacktraces.append(line)
            elif len(at_lines) >= 1:
                # Standalone stacktrace frames: any "at" lines (could be truncated stacktrace)
                stacktraces.append(line)
        return stacktraces

    def extract_tracebacks_from_logs(self, logs: list[str]) -> list[str]:
        """
        Extract Java stacktraces from a given list of logs.
        
        This is the main method that processes log entries to extract Java stacktraces.
        It handles log reconstruction (combining split log entries) and filtering
        to identify logs containing stacktrace information.
        
        The method performs the following steps:
        1. Normalizes input to ensure it's a list of strings
        2. Reconstructs multi-line log entries that may have been split
        3. Filters logs to find those containing stacktrace information
        
        Args:
            logs (list[str]): List of log entries to process. Can also accept
                             a single string which will be converted to a list.
                             
        Returns:
            list[str]: List of log entries that contain Java stacktrace information
            
        Example:
            >>> extractor = JavaTracebackExtractor()
            >>> logs = [
            ...     "2024-01-15T10:30:45.123Z INFO: Application started",
            ...     "2024-01-15T10:30:46.456Z Exception in thread main: java.lang.NullPointerException",
            ...     "    at com.example.Class.method(Class.java:123)",
            ...     "    at com.example.AnotherClass.anotherMethod(AnotherClass.java:456)"
            ... ]
            >>> stacktraces = extractor.extract_tracebacks_from_logs(logs)
            >>> len(stacktraces) > 0
            True
        """
        # ensure we have a list of logs
        logs_as_str_list = []
        if isinstance(logs, list):
            logs_as_str_list = logs
        else:
            logs_as_str_list = [str(logs)]
        
        actual_logs = []

        for line in logs_as_str_list:
            if self.has_timestamp_at_alphanumeric_start(line):
                actual_logs.append(line)
            else:
                if not actual_logs:
                    actual_logs.append(line)
                else:
                    actual_logs[-1] += f'\n{line}'
        
        return self.filter_logs_having_trace(actual_logs)    
