"""
Timestamp Handling Module for Log Analysis

This module provides comprehensive functionality for handling timestamps in log files.
It supports multiple timestamp formats commonly found in Java application logs and
provides utilities for parsing, extracting, and manipulating timestamp data.

Key Features:
- Detection of multiple timestamp formats (DD-MM-YYYY, ISO 8601, etc.)
- Extraction of timestamps from log lines with position information
- Parsing timestamp strings to datetime objects
- Finding earliest/latest timestamps in multi-line log entries
- Removing timestamps for content-based comparison
- Robust handling of various timestamp edge cases

Supported Timestamp Formats:
- DD-MM-YYYY HH:MM:SS.mmm (e.g., "15-01-2024 10:30:45.123")
- ISO 8601 (e.g., "2024-01-15T10:30:45.123Z", "2024-01-15T10:30:45.123456789Z")
- YYYY-MM-DD HH:MM:SS.nnn (e.g., "2024-01-15 10:30:45.123")

Usage:
    handler = TimestampHandler()
    timestamp = handler.extract_timestamp_from_line(log_line)
    dt = handler.parse_timestamp_to_datetime(timestamp)

Author: akshayrw25
"""

import re
from datetime import datetime
from typing import Optional, Tuple, List


class TimestampHandler:
    """
    A comprehensive handler for timestamp operations in log analysis.
    
    This class provides methods for detecting, extracting, parsing, and manipulating
    timestamps in various formats commonly found in Java application logs. It supports
    multiple timestamp patterns and provides robust error handling for edge cases.
    
    The class is designed to be stateless and thread-safe, making it suitable for
    use in concurrent log processing environments.
    
    Attributes:
        TIMESTAMP_PATTERNS (List[str]): Regex patterns for supported timestamp formats
    """
    
    # List of timestamp patterns to handle
    TIMESTAMP_PATTERNS = [
        r'^\d{2}-\d{2}-\d{4}\s\d{2}:\d{2}:\d{2}\.\d{3}',  # DD-MM-YYYY HH:MM:SS.mmm
        r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z?',   # ISO 8601: YYYY-MM-DDTHH:MM:SS.nnnnnnnZ
        r'^\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}\.\d+'     # YYYY-MM-DD HH:MM:SS.nnn
    ]
    
    def matches_any_timestamp_pattern(self, text: str) -> bool:
        """
        Check if text matches any of the supported timestamp patterns.
        
        This method validates whether the provided text starts with a recognized
        timestamp format. It supports multiple common timestamp patterns used in
        Java application logs.
        
        Args:
            text (str): The text to check for timestamp patterns
            
        Returns:
            bool: True if the text matches any supported timestamp pattern, False otherwise
            
        Example:
            >>> handler = TimestampHandler()
            >>> handler.matches_any_timestamp_pattern("2024-01-15T10:30:45.123Z")
            True
            >>> handler.matches_any_timestamp_pattern("15-01-2024 10:30:45.123")
            True
            >>> handler.matches_any_timestamp_pattern("INFO: Application started")
            False
        """
        if not text.strip():
            return False
        
        for pattern in self.TIMESTAMP_PATTERNS:
            if re.match(pattern, text.strip()):
                return True
        return False

    def has_timestamp_at_alphanumeric_start(self, line: str) -> bool:
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
            >>> handler = TimestampHandler()
            >>> handler.has_timestamp_at_alphanumeric_start("2024-01-15T10:30:45.123Z INFO: Application started")
            True
            >>> handler.has_timestamp_at_alphanumeric_start("    at com.example.Class.method(Class.java:123)")
            False
            >>> handler.has_timestamp_at_alphanumeric_start("   Caused by: java.lang.NullPointerException")
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

    def extract_timestamp_from_line(self, log_line: str) -> Tuple[Optional[str], Optional[int], Optional[int]]:
        """
        Extract timestamp from a log line using the defined patterns.
        
        This method searches for timestamp patterns in a log line and extracts the first
        matching timestamp. It can optionally return position information for the timestamp
        within the line, which is useful for timestamp removal or replacement operations.
        
        Args:
            log_line (str): The log line to extract timestamp from
            
        Returns:
            - tuple (timestamp, start_pos, end_pos) or (None, None, None)
        
        Example:
            >>> handler = TimestampHandler()
            >>> handler.extract_timestamp_from_line("2024-01-15T10:30:45.123Z ERROR: Something failed")
            ('2024-01-15T10:30:45.123Z', 0, 24)
            >>> timestamp, start, end = handler.extract_timestamp_from_line(
            ...     "2024-01-15T10:30:45.123Z ERROR")
            >>> timestamp
            '2024-01-15T10:30:45.123Z'
        """
        cleaned_line = log_line.strip()
        if not cleaned_line:
            return None, None, None
        
        # Find the first alphanumeric character
        first_alnum_pos = None
        for char_index, char in enumerate(cleaned_line):
            if char.isalnum():
                first_alnum_pos = char_index
                break
        
        if first_alnum_pos is None:
            return None, None, None
        
        # Check if timestamp pattern exists from that position
        remaining_text = cleaned_line[first_alnum_pos:]
        
        for timestamp_pattern in self.TIMESTAMP_PATTERNS:
            match = re.search(timestamp_pattern, remaining_text)
            if match:
                timestamp = match.group(0)
                start_pos, end_pos = match.span()
                
                return timestamp, start_pos, end_pos
        
        # No timestamp found
        return None, None, None

    def parse_timestamp_to_datetime(self, timestamp_str: str) -> Optional[datetime]:
        """
        Parse timestamp string to datetime object using known patterns.
        
        This method attempts to parse a timestamp string using multiple datetime format
        patterns. It handles special cases like nanosecond precision timestamps by
        truncating them to microsecond precision (Python's datetime limit).
        
        Args:
            timestamp_str (str): The timestamp string to parse
            
        Returns:
            datetime: Parsed datetime object if successful
            None: If parsing fails or input is empty
            
        Example:
            >>> handler = TimestampHandler()
            >>> dt = handler.parse_timestamp_to_datetime("2024-01-15T10:30:45.123Z")
            >>> dt.year
            2024
            >>> dt = handler.parse_timestamp_to_datetime("15-01-2024 10:30:45.123")
            >>> dt.month
            1
        """
        if not timestamp_str:
            return None
        
        # Handle nanosecond precision in ISO timestamps by truncating to microseconds
        normalized_timestamp = timestamp_str
        if 'T' in normalized_timestamp and normalized_timestamp.endswith('Z'):
            # Split at the decimal point
            parts = normalized_timestamp.rstrip('Z').split('.')
            if len(parts) == 2 and len(parts[1]) > 6:
                # Truncate to 6 digits (microseconds) - Python datetime limit
                normalized_timestamp = f"{parts[0]}.{parts[1][:6]}Z"
        
        # Define datetime patterns corresponding to timestamp patterns
        datetime_patterns = [
            '%d-%m-%Y %H:%M:%S.%f',  # DD-MM-YYYY HH:MM:SS.mmm
            '%Y-%m-%dT%H:%M:%S.%fZ', # ISO 8601: YYYY-MM-DDTHH:MM:SS.nnnnnnnZ
            '%Y-%m-%dT%H:%M:%S.%f',  # ISO 8601 without Z
            '%Y-%m-%d %H:%M:%S.%f'   # YYYY-MM-DD HH:MM:SS.nnn
        ]
        
        for datetime_pattern in datetime_patterns:
            try:
                return datetime.strptime(normalized_timestamp, datetime_pattern)
            except ValueError:
                continue
        
        return None
    
    def get_timestamp_from_stacktrace(self, stacktrace: str, get_min: bool = False, debug: bool = False) -> Optional[datetime]:
        """
        Extract the earliest or latest timestamp from a stacktrace.
        
        This function analyzes a stacktrace (which may be multi-line) and extracts
        either the earliest (minimum) or latest (maximum) timestamp found within it.
        This is useful for determining the time range of a particular error event.
        
        Args:
            stacktrace (str): The stacktrace text to analyze
            get_min (bool): If True, returns the earliest timestamp; if False, returns the latest
            debug (bool): If True, prints debug information during processing
        
        Returns:
            datetime: The earliest or latest timestamp found in the stacktrace
            None: If no valid timestamps are found
            
        Example:
            >>> handler = TimestampHandler()
            >>> stacktrace = "2024-01-15T10:30:45.123Z ERROR: NullPointerException\\n" + \\
            ...              "    at com.example.Class.method(Class.java:123)"
            >>> dt = handler.get_timestamp_from_stacktrace(stacktrace)
            >>> dt.year
            2024
        """
        if not stacktrace:
            return None
        
        # Split into lines if multi-line stacktrace
        stacktrace_lines = stacktrace.split('\n') if '\n' in stacktrace else [stacktrace]
        result_datetime = None
        
        if debug:
            print(f"\n\tGetting {'min' if get_min else 'max'} timestamp from stacktrace: {stacktrace}\n")
        
        for line in stacktrace_lines:
            timestamp_str, _, _ = self.extract_timestamp_from_line(line)
            if timestamp_str:
                parsed_datetime = self.parse_timestamp_to_datetime(timestamp_str)
                
                if debug:
                    print(f"\n\tTimestamp string: {timestamp_str}\n"
                          f"\n\t\t->Parsed datetime: {parsed_datetime}\n")
                
                if parsed_datetime:
                    # Update result if:
                    # 1. This is the first timestamp we've found, or
                    # 2. We want the earliest and this one is earlier, or
                    # 3. We want the latest and this one is later
                    if (result_datetime is None or 
                        (get_min and parsed_datetime < result_datetime) or 
                        (not get_min and parsed_datetime > result_datetime)):
                        result_datetime = parsed_datetime
        
        return result_datetime

    def get_min_timestamp_from_stacktrace(self, stacktrace: str, debug: bool = False) -> Optional[datetime]:
        """
        Get the earliest timestamp from a stacktrace.
        
        This is a convenience wrapper around get_timestamp_from_stacktrace()
        specifically for getting the minimum (earliest) timestamp.
        
        Args:
            stacktrace (str): The stacktrace text to analyze
            debug (bool): If True, prints debug information
            
        Returns:
            datetime: The earliest timestamp found in the stacktrace
            None: If no valid timestamps are found
        """
        return self.get_timestamp_from_stacktrace(stacktrace, get_min=True, debug=debug)

    def get_max_timestamp_from_stacktrace(self, stacktrace: str, debug: bool = False) -> Optional[datetime]:
        """
        Get the latest timestamp from a stacktrace.
        
        This is a convenience wrapper around get_timestamp_from_stacktrace()
        specifically for getting the maximum (latest) timestamp.
        
        Args:
            stacktrace (str): The stacktrace text to analyze
            debug (bool): If True, prints debug information
            
        Returns:
            datetime: The latest timestamp found in the stacktrace
            None: If no valid timestamps are found
        """
        return self.get_timestamp_from_stacktrace(stacktrace, get_min=False, debug=debug)

    def remove_timestamps_from_stacktrace(self, stacktrace: str) -> Tuple[str, List[Tuple[int, int, str]]]:
        """
        Remove timestamp patterns from a stacktrace to facilitate deduplication.
        
        This method processes a stacktrace and replaces all timestamps with a placeholder,
        while keeping track of the original timestamp positions and values. This allows
        for content-based comparison of stacktraces that may differ only in their timestamps.
        
        The method is particularly useful for:
        - Deduplicating stacktraces that are identical except for timestamps
        - Normalizing stacktraces for pattern matching
        - Preserving timestamp information for potential restoration
        
        Args:
            stacktrace (str): The stacktrace text to process
            
        Returns:
            tuple: A tuple containing:
                - str: The normalized stacktrace with timestamps replaced by placeholders
                - list: A list of tuples (start_pos, end_pos, timestamp) recording the
                  original positions and values of the timestamps
                  
        Example:
            >>> handler = TimestampHandler()
            >>> normalized, positions = handler.remove_timestamps_from_stacktrace(
            ...     "2024-01-15T10:30:45.123Z ERROR: NullPointerException")
            >>> "TIMESTAMP_PLACEHOLDER" in normalized
            True
            >>> len(positions) > 0
            True
        """
        if not stacktrace:
            return "", []
        
        # Split stacktrace into lines for processing
        stacktrace_lines = stacktrace.split('\n')
        normalized_lines = []
        timestamp_positions = []
        char_position = 0  # Track absolute character position in the stacktrace
        
        for line in stacktrace_lines:
            # Extract timestamp with position information
            timestamp, start_pos, end_pos = self.extract_timestamp_from_line(line)
            
            if timestamp:
                # Store the absolute position and the timestamp
                absolute_start = char_position + start_pos
                absolute_end = char_position + end_pos
                timestamp_positions.append((absolute_start, absolute_end, timestamp))
                
                # Replace timestamp with a placeholder
                normalized_line = line[:start_pos] + "TIMESTAMP_PLACEHOLDER" + line[end_pos:]
                normalized_lines.append(normalized_line)
            else:
                normalized_lines.append(line)
            
            # Update character position (+1 for the newline that will be added when joining)
            char_position += len(line) + 1
        
        return '\n'.join(normalized_lines), timestamp_positions
