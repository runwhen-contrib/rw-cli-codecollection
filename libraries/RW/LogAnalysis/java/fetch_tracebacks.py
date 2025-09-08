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

import ast
import re
from datetime import datetime
from robot.api import logger

# List of timestamp patterns to handle
TIMESTAMP_PATTERNS = [
    r'^\d{2}-\d{2}-\d{4}\s\d{2}:\d{2}:\d{2}\.\d{3}',  # DD-MM-YYYY HH:MM:SS.mmm
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z?',   # ISO 8601: YYYY-MM-DDTHH:MM:SS.nnnnnnnZ
    r'^\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}\.\d+'     # YYYY-MM-DD HH:MM:SS.nnn
]
JAVA_PATTERN = re.compile(r'\s*at\s+[a-zA-Z_][\w$]*(\.[a-zA-Z_][\w$]*)+\([^)]*\)')


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

    def extract_timestamp_from_line(self, log_line: str, return_position: bool = False) -> tuple[str, int, int] | str | None:
        """
        Extract timestamp from a log line using the defined patterns.
        
        Args:
            log_line: The log line to extract timestamp from
            return_position: If True, returns a tuple (timestamp, start_pos, end_pos)
        
        Returns:
            - If return_position=False: timestamp string or None
            - If return_position=True: tuple (timestamp, start_pos, end_pos) or (None, None, None)
        
        Example:
            >>> extractor = JavaTracebackExtractor()
            >>> extractor.extract_timestamp_from_line("2024-01-15T10:30:45.123Z ERROR: Something failed")
            '2024-01-15T10:30:45.123Z'
            >>> timestamp, start, end = extractor.extract_timestamp_from_line(
            ...     "2024-01-15T10:30:45.123Z ERROR", return_position=True)
            >>> timestamp
            '2024-01-15T10:30:45.123Z'
        """
        cleaned_line = log_line.strip()
        if not cleaned_line:
            if return_position:
                return None, None, None
            else:
                return None
        
        # Find the first alphanumeric character
        first_alnum_pos = None
        for char_index, char in enumerate(cleaned_line):
            if char.isalnum():
                first_alnum_pos = char_index
                break
        
        if first_alnum_pos is None:
            if return_position:
                return None, None, None
            else:
                return None
        
        # Check if timestamp pattern exists from that position
        remaining_text = cleaned_line[first_alnum_pos:]
        
        for timestamp_pattern in TIMESTAMP_PATTERNS:
            match = re.search(timestamp_pattern, remaining_text)
            if match:
                timestamp = match.group(0)
                start_pos, end_pos = match.span()
                
                if return_position:
                    return timestamp, start_pos, end_pos
                else:
                    return timestamp
        
        # No timestamp found
        if return_position:
            return None, None, None
        else:
            return None

    def parse_timestamp_to_datetime(self, timestamp_str: str) -> datetime | None:
        """
        Parse timestamp string to datetime object using known patterns.
        
        Args:
            timestamp_str: The timestamp string to parse
            
        Returns:
            datetime: Parsed datetime object if successful
            None: If parsing fails or input is empty
            
        Example:
            >>> extractor = JavaTracebackExtractor()
            >>> dt = extractor.parse_timestamp_to_datetime("2024-01-15T10:30:45.123Z")
            >>> dt.year
            2024
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
    
    def get_timestamp_from_stacktrace(self, stacktrace: str, get_min: bool = False, debug: bool = False) -> datetime | None:
        """
        Extract the earliest or latest timestamp from a stacktrace.
        
        This function analyzes a stacktrace (which may be multi-line) and extracts
        either the earliest (minimum) or latest (maximum) timestamp found within it.
        
        Args:
            stacktrace: The stacktrace text to analyze
            get_min: If True, returns the earliest timestamp; if False, returns the latest
            debug: If True, prints debug information during processing
        
        Returns:
            datetime: The earliest or latest timestamp found in the stacktrace
            None: If no valid timestamps are found
            
        Example:
            >>> extractor = JavaTracebackExtractor()
            >>> stacktrace = "2024-01-15T10:30:45.123Z ERROR: NullPointerException\\n" + \\
            ...              "    at com.example.Class.method(Class.java:123)"
            >>> dt = extractor.get_timestamp_from_stacktrace(stacktrace)
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
            timestamp_str = self.extract_timestamp_from_line(line)
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

    # Wrapper functions for backward compatibility and clarity
    def get_min_timestamp_from_stacktrace(self, stacktrace: str, debug: bool = False) -> datetime | None:
        """
        Get the earliest timestamp from a stacktrace.
        
        Args:
            stacktrace: The stacktrace text to analyze
            debug: If True, prints debug information
            
        Returns:
            datetime: The earliest timestamp found in the stacktrace
            None: If no valid timestamps are found
        """
        return self.get_timestamp_from_stacktrace(stacktrace, get_min=True, debug=debug)

    def get_max_timestamp_from_stacktrace(self, stacktrace: str, debug: bool = False) -> datetime | None:
        """
        Get the latest timestamp from a stacktrace.
        
        Args:
            stacktrace: The stacktrace text to analyze
            debug: If True, prints debug information
            
        Returns:
            datetime: The latest timestamp found in the stacktrace
            None: If no valid timestamps are found
        """
        return self.get_timestamp_from_stacktrace(stacktrace, get_min=False, debug=debug)

    def is_single_line_stacktrace(self, stacktrace: str) -> bool:
        """
        Check if a stacktrace consists of a single line.
        
        Args:
            stacktrace: The stacktrace text to check
            
        Returns:
            bool: True if the stacktrace has no newlines, False otherwise
        """
        return '\n' not in stacktrace.strip()

    def is_multi_line_stacktrace(self, stacktrace: str) -> bool:
        """
        Check if a stacktrace consists of multiple lines.
        
        Args:
            stacktrace: The stacktrace text to check
            
        Returns:
            bool: True if the stacktrace contains newlines, False otherwise
        """
        return '\n' in stacktrace.strip()

    def aggregate_java_stacktraces(self, stacktraces: list[str]) -> list[str]:
        """
        Aggregate Java stacktraces based on timestamp proximity and format.
        
        This method intelligently combines related stacktraces based on their timestamps
        and structure (single-line vs multi-line). It implements the following logic:
        
        1. If current stacktrace has no timestamp:
           - If next stacktrace has timestamp and is multi-line, keep both separately
           - Otherwise, combine them
        
        2. If current stacktrace has timestamp but next doesn't:
           - Always combine them (next is likely a continuation)
        
        3. If both have timestamps:
           - If timestamps are within 1 minute of each other:
             - If both are multi-line, keep separate
             - Otherwise, combine them
           - If timestamps differ by more than 1 minute:
             - If current is single-line, replace it with next
             - If current is multi-line, keep both separately
        
        Args:
            stacktraces: List of stacktrace strings to aggregate
            
        Returns:
            list[str]: Aggregated list of stacktraces
            
        Note:
            Single-line stacktraces without timestamps are generally discarded
            as they typically lack sufficient context for analysis.
        """
        if not stacktraces:
            return stacktraces
            
        if len(stacktraces) == 1:
            # If single entry is multi-line stacktrace, retain it; otherwise return empty list
            if self.is_multi_line_stacktrace(stacktraces[0]):
                return stacktraces
            else:
                return []
        
        # Initialize results with the first stacktrace
        results = stacktraces[:1]
        current_index, next_index = 0, 1
        
        while next_index < len(stacktraces):
            current_stacktrace = results[current_index]
            next_stacktrace = stacktraces[next_index]
            
            # Get timestamps from both stacktraces
            current_timestamp = self.get_max_timestamp_from_stacktrace(current_stacktrace)
            next_timestamp = self.get_min_timestamp_from_stacktrace(next_stacktrace)
            
            # Determine stacktrace formats
            is_current_single_line = self.is_single_line_stacktrace(current_stacktrace)
            is_current_multi_line = self.is_multi_line_stacktrace(current_stacktrace)
            is_next_single_line = self.is_single_line_stacktrace(next_stacktrace)
            is_next_multi_line = self.is_multi_line_stacktrace(next_stacktrace)

            # CASE 1: Current stacktrace has no timestamp
            if current_timestamp is None:
                if next_timestamp and is_next_multi_line:
                    # If next has timestamp and is multi-line, keep it separate
                    results.append(next_stacktrace)
                else:
                    # Otherwise combine them
                    results[current_index] += f"\n{next_stacktrace}"
                next_index += 1
                continue
            
            # CASE 2: Current has timestamp but next doesn't
            if current_timestamp and not next_timestamp:
                # Always combine them (next is likely a continuation)
                results[current_index] += f"\n{next_stacktrace}"
                next_index += 1
                continue

            # CASE 3: Both stacktraces have timestamps
            if current_timestamp and next_timestamp:
                # Calculate time difference in seconds
                time_diff = abs((current_timestamp - next_timestamp).total_seconds())
                
                # If time difference is less than 1 minute (60 seconds)
                if time_diff < 60:
                    if is_current_multi_line and is_next_multi_line:
                        # Both are multi-line, keep separate
                        results.append(next_stacktrace)
                        current_index += 1
                        next_index += 1
                    else:
                        # At least one is single-line, combine them
                        results[current_index] += f"\n{next_stacktrace}"
                        next_index += 1
                else:
                    # Time difference >= 1 minute
                    if is_current_single_line:
                        # Current is single-line, replace it with next
                        results.pop(-1)
                        results.append(next_stacktrace)
                        next_index += 1
                    elif is_current_multi_line:
                        # Current is multi-line, keep both
                        results.append(next_stacktrace)
                        current_index += 1
                        next_index += 1
            
            # Check if we've processed the last stacktrace
            if next_index == len(stacktraces):
                # Remove single-line stacktraces at the end as they're not useful alone
                if self.is_single_line_stacktrace(results[current_index]):
                    results.pop(current_index)

        return results

    def remove_timestamps_from_stacktrace(self, stacktrace: str) -> tuple[str, list[tuple[int, int, str]]]:
        """
        Remove timestamp patterns from a stacktrace to facilitate deduplication.
        
        This method processes a stacktrace and replaces all timestamps with a placeholder,
        while keeping track of the original timestamp positions and values. This allows
        for content-based comparison of stacktraces that may differ only in their timestamps.
        
        Args:
            stacktrace: The stacktrace text to process
            
        Returns:
            tuple: A tuple containing:
                - str: The normalized stacktrace with timestamps replaced by placeholders
                - list: A list of tuples (start_pos, end_pos, timestamp) recording the
                  original positions and values of the timestamps
                  
        Example:
            >>> extractor = JavaTracebackExtractor()
            >>> normalized, positions = extractor.remove_timestamps_from_stacktrace(
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
            timestamp, start_pos, end_pos = self.extract_timestamp_from_line(line, return_position=True)
            
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

    def deduplicate_stacktraces(self, stacktraces: list[str]) -> list[str]:
        """
        Deduplicate stacktraces by ignoring timestamp differences.
        
        This method identifies and removes duplicate stacktraces that differ only in their
        timestamps. When duplicates are found, it keeps the one with the latest timestamp.
        The results are sorted chronologically based on timestamp windows.
        
        Sorting logic:
        - Stacktraces with no timestamps are placed at the end
        - Non-overlapping timestamp windows are sorted chronologically
        - Overlapping windows are sorted by earliest start time
        
        Args:
            stacktraces: List of stacktrace strings to deduplicate
            
        Returns:
            list[str]: Deduplicated list of stacktraces, sorted chronologically
            
        Example:
            >>> extractor = JavaTracebackExtractor()
            >>> traces = [
            ...     "2024-01-15T10:30:45.123Z ERROR: NullPointerException",
            ...     "2024-01-15T10:35:45.123Z ERROR: NullPointerException"  # Same error, different time
            ... ]
            >>> len(extractor.deduplicate_stacktraces(traces))
            1
        """
        if not stacktraces:
            return []
        
        # Dictionary to store normalized stacktrace -> (original stacktrace, min_timestamp, max_timestamp)
        unique_traces = {}
        
        for stacktrace in stacktraces:
            # Remove timestamps for comparison
            normalized_stacktrace, _ = self.remove_timestamps_from_stacktrace(stacktrace)
            
            # Get the min and max timestamps from this stacktrace
            min_timestamp = self.get_min_timestamp_from_stacktrace(stacktrace)
            max_timestamp = self.get_max_timestamp_from_stacktrace(stacktrace)
            
            # If this normalized trace is not yet in our unique traces, add it
            if normalized_stacktrace not in unique_traces:
                unique_traces[normalized_stacktrace] = (stacktrace, min_timestamp, max_timestamp)
            else:
                # If we already have this trace, check if the current one has a later timestamp
                _, existing_min, existing_max = unique_traces[normalized_stacktrace]
                
                # Replace if:
                # 1. Current has timestamp but existing doesn't, or
                # 2. Both have timestamps and current is more recent
                if (max_timestamp and not existing_max) or \
                   (max_timestamp and existing_max and max_timestamp > existing_max):
                    unique_traces[normalized_stacktrace] = (stacktrace, min_timestamp, max_timestamp)
        
        # Get the unique stacktraces with their timestamp windows
        unique_stacktraces_with_timestamps = [
            (trace, min_ts, max_ts) for trace, min_ts, max_ts in unique_traces.values()
        ]
        
        # Define a custom sorting function based on timestamp windows
        def sort_by_timestamp_windows(item: tuple[str, datetime | None, datetime | None]) -> tuple:
            trace, min_ts, max_ts = item
            # If no timestamps, put at the end
            if min_ts is None:
                # Use a far future date
                future_date = datetime(9999, 12, 31, 23, 59, 59)
                return (future_date, future_date)
            # Return tuple of (min_timestamp, max_timestamp) for sorting
            return (min_ts, max_ts)
        
        # Sort the stacktraces based on timestamp windows
        try:
            sorted_stacktraces = sorted(unique_stacktraces_with_timestamps, key=sort_by_timestamp_windows)
        except Exception as e:
            logger.error(f"Exception encountered while sorting stacktraces: {e}")
            # Fall back to unsorted if sorting fails
            sorted_stacktraces = unique_stacktraces_with_timestamps
        
        # Return just the original stacktraces in the sorted order
        return [trace for trace, _, _ in sorted_stacktraces]


    def filter_logs_having_trace(self, logs: list[str]) -> list[str]:
        """
        Filter logs to extract only those containing Java stacktrace information.
        
        This method analyzes each log entry to determine if it contains
        Java stacktrace frames. It organizes logs into blocks of related stacktrace
        entries and then aggregates them. It identifies two types of stacktrace content:
        
        1. Complete stacktraces: logs containing both "exception" keyword and stacktrace frames
        2. Standalone stacktrace frames: logs containing at least one stacktrace frame
        
        Args:
            logs: List of log entries to filter
            
        Returns:
            list[str]: List of log entries that contain stacktrace information
            
        Note:
            The method handles multi-line log entries by splitting on newlines
            and checking each line for stacktrace patterns. It groups related
            stacktrace entries together before aggregation.
            
        Example:
            >>> extractor = JavaTracebackExtractor()
            >>> logs = [
            ...     "INFO: Application started",
            ...     "Exception in thread main: java.lang.NullPointerException\n    at com.example.Class.method(Class.java:123)"
            ... ]
            >>> stacktraces = extractor.filter_logs_having_trace(logs)
            >>> len(stacktraces) > 0 and "Exception" in stacktraces[0]
            True
        """
        # Initialize with an empty block to collect stacktrace entries
        stacktrace_blocks = [[]]
        
        for log_entry in logs:
            # Split multi-line log entries
            log_lines = log_entry.split("\n")
            
            # Clean up each line (remove leading dashes and dollar signs)
            cleaned_lines = [line.strip().lstrip('-').lstrip('$') for line in log_lines]
            
            # Filter out empty lines
            valid_lines = [line for line in cleaned_lines if line]
            
            # Reconstruct the log entry with cleaned lines
            formatted_log = "\n".join(valid_lines)
            
            # Identify lines that contain stacktrace frames
            stacktrace_frame_lines = [
                line for line in valid_lines if self.line_starts_with_at(line)
            ]
            
            # Check if this log contains stacktrace information
            if ("exception" in formatted_log.lower() and stacktrace_frame_lines) or len(stacktrace_frame_lines) >= 1:
                # This is a stacktrace entry - add it to the current block
                stacktrace_blocks[-1].append(formatted_log)
            else:
                # Not a stacktrace entry - start a new block for future entries
                # Only create a new block if the current one isn't empty
                if stacktrace_blocks[-1]:
                    stacktrace_blocks.append([])

        # Process each block of related stacktrace entries
        aggregated_stacktraces = []
        for block in stacktrace_blocks:
            # Skip empty blocks
            if block:
                # Aggregate related stacktraces within each block
                aggregated_stacktraces.extend(self.aggregate_java_stacktraces(block))
        
        return aggregated_stacktraces

    def extract_tracebacks_from_logs(self, logs: list[str] | str) -> list[str]:
        """
        Extract Java stacktraces from log entries.
        
        This is the main method for extracting Java stacktraces from logs. It performs
        the following steps:
        
        1. Normalizes input to ensure it's a list of strings
        2. Reconstructs multi-line log entries that may have been split across lines
        3. Filters and identifies logs containing stacktrace information
        4. Aggregates related stacktrace entries
        
        Args:
            logs: Log entries to process. Can be either:
                - A list of log line strings
                - A single string (which will be converted to a list)
                             
        Returns:
            list[str]: List of extracted Java stacktraces
            
        Example:
            >>> extractor = JavaTracebackExtractor()
            >>> logs = [
            ...     "2024-01-15T10:30:45.123Z INFO: Application started",
            ...     "2024-01-15T10:30:46.456Z Exception in thread main: java.lang.NullPointerException",
            ...     "    at com.example.Class.method(Class.java:123)",
            ...     "    at com.example.AnotherClass.anotherMethod(AnotherClass.java:456)"
            ... ]
            >>> stacktraces = extractor.extract_tracebacks_from_logs(logs)
            >>> len(stacktraces) > 0 and "NullPointerException" in stacktraces[0]
            True
        """
        # Normalize input to ensure we have a list of log lines
        log_lines = []
        if isinstance(logs, list):
            log_lines = logs
        else:
            log_lines = [str(logs)]    
        
        # Reconstruct multi-line log entries that may have been split
        reconstructed_logs = []

        for line in log_lines:
            cleaned_line = line.strip()
            
            # If line starts with a timestamp, it's likely a new log entry
            if self.has_timestamp_at_alphanumeric_start(cleaned_line):
                reconstructed_logs.append(cleaned_line)
            else:
                # No timestamp - this is likely a continuation of the previous log entry
                if not reconstructed_logs:
                    # If this is the first line with no timestamp, start a new entry
                    reconstructed_logs.append(cleaned_line)
                else:
                    # Append to the previous entry with a newline
                    reconstructed_logs[-1] += f'\n{cleaned_line}'

        # Filter logs to find those containing stacktrace information
        return self.filter_logs_having_trace(reconstructed_logs)

    def extract_tracebacks_from_logs_dir(self, log_files: list[str]) -> list[str]:
        """
        Extract Java stacktraces from multiple log files.
        
        This method processes a list of log files, extracts stacktraces from each,
        and returns a deduplicated list of all found stacktraces.
        
        Args:
            log_files: List of paths to log files to process
            
        Returns:
            list[str]: List of unique Java stacktraces found across all files,
                      deduplicated and sorted by timestamp
                      
        Note:
            This method handles file reading errors gracefully, logging them
            but continuing with other files.
        """
        all_stacktraces = []
        processed_files = 0
        
        # Process each log file
        for log_file_path in log_files:
            try:
                try:
                    log_lines = ast.literal_eval(open(log_file_path, 'r').readlines()[0])[0].split("\n")
                except Exception as e:
                    # Read the log file line by line
                    with open(log_file_path, 'r', encoding='utf-8', errors='ignore') as file:
                        log_lines = [line.rstrip('\n') for line in file]
                
                # Extract stacktraces from this file
                file_stacktraces = self.extract_tracebacks_from_logs(log_lines)
                all_stacktraces.extend(file_stacktraces)
                processed_files += 1
                
            except Exception as e:
                logger.error(f"Error processing log file {log_file_path}: {str(e)}")
                continue
        
        # Deduplicate stacktraces across all files
        unique_stacktraces = self.deduplicate_stacktraces(all_stacktraces)
        
        return unique_stacktraces
