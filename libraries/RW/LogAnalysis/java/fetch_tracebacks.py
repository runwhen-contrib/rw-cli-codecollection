"""
Java Stacktrace Extraction Module

This module provides comprehensive functionality to extract and analyze Java stacktraces 
from log files. It processes multiple log files, intelligently reconstructs fragmented 
log entries, identifies stacktrace patterns, and performs deduplication and aggregation.

Processing Flow:
1. File Processing: Reads multiple log files with robust error handling
2. Log Reconstruction: Reassembles multi-line log entries split across lines using timestamp detection
3. Stacktrace Identification: Filters logs to find Java stacktrace patterns and exception information
4. Intelligent Aggregation: Groups related stacktrace entries based on timestamp proximity and content
5. Deduplication: Removes duplicate stacktraces while preserving chronological order
6. Output: Returns a clean list of unique, meaningful stacktraces

Key Features:
- Batch processing of multiple log files (primary entry point: extract_tracebacks_from_logs_dir)
- Intelligent timestamp handling via separate TimestampHandler class
- Support for various timestamp formats (DD-MM-YYYY, ISO 8601, YYYY-MM-DD)
- Robust multi-line log entry reconstruction
- Advanced stacktrace aggregation based on temporal and content analysis
- Content-based deduplication ignoring timestamp variations
- Comprehensive error handling and logging

Architecture:
- JavaTracebackExtractor: Main processing engine for stacktrace extraction and analysis
- TimestampHandler: Specialized class for all timestamp-related operations
- Separation of concerns for better maintainability and reusability

Entry Point Usage:
    extractor = JavaTracebackExtractor()
    stacktraces = extractor.extract_tracebacks_from_logs_dir(log_file_paths)

Individual Log Processing:
    extractor = JavaTracebackExtractor()
    stacktraces = extractor.extract_tracebacks_from_logs(log_lines)

Author: akshayrw25
"""

import ast
import re
from datetime import datetime
from robot.api import logger
from timestamp_handler import TimestampHandler

JAVA_PATTERN = re.compile(r'\s*at\s+[a-zA-Z_][\w$]*(\.[a-zA-Z_][\w$]*)+\([^)]*\)')


class JavaTracebackExtractor:
    """
    Java Stacktrace Extractor for log analysis.
    
    This class provides functionality to extract Java stacktraces from log files.
    It handles various log formats and can identify stacktrace patterns even when
    logs are split across multiple lines.
    
    Key Features:
    - Extracts Java stacktraces from log entries
    - Reconstructs multi-line log entries that may have been split
    - Filters logs to find those containing stacktrace information
    - Supports both complete stacktraces (with exceptions) and standalone stacktrace frames
    - Aggregates and deduplicates related stacktraces
    
    The class uses a separate TimestampHandler for all timestamp-related operations,
    promoting separation of concerns and code reusability.
    """
    
    def __init__(self):
        """Initialize the JavaTracebackExtractor with a TimestampHandler instance."""
        self.timestamp_handler = TimestampHandler()
    
    def matches_any_timestamp_pattern(self, text):
        """
        Check if text matches any of the supported timestamp patterns.
        
        Delegates to TimestampHandler for timestamp pattern matching.
        
        Args:
            text (str): The text to check for timestamp patterns
            
        Returns:
            bool: True if the text matches any supported timestamp pattern, False otherwise
        """
        return self.timestamp_handler.matches_any_timestamp_pattern(text)

    def has_timestamp_at_alphanumeric_start(self, line):
        """
        Check if there's a timestamp pattern starting from the first alphanumeric character.
        
        Delegates to TimestampHandler for timestamp detection logic.
        
        Args:
            line (str): The log line to analyze
            
        Returns:
            bool: True if a timestamp pattern is found starting from the first
                  alphanumeric character, False otherwise
        """
        return self.timestamp_handler.has_timestamp_at_alphanumeric_start(line)

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

    def extract_timestamp_from_line(self, log_line: str, return_position: bool = False):
        """
        Extract timestamp from a log line using the defined patterns.
        
        Delegates to TimestampHandler for timestamp extraction logic.
        
        Args:
            log_line: The log line to extract timestamp from
            return_position: If True, returns a tuple (timestamp, start_pos, end_pos)
        
        Returns:
            - If return_position=False: timestamp string or None
            - If return_position=True: tuple (timestamp, start_pos, end_pos) or (None, None, None)
        """
        return self.timestamp_handler.extract_timestamp_from_line(log_line, return_position)

    def parse_timestamp_to_datetime(self, timestamp_str: str):
        """
        Parse timestamp string to datetime object using known patterns.
        
        Delegates to TimestampHandler for timestamp parsing logic.
        
        Args:
            timestamp_str: The timestamp string to parse
            
        Returns:
            datetime: Parsed datetime object if successful
            None: If parsing fails or input is empty
        """
        return self.timestamp_handler.parse_timestamp_to_datetime(timestamp_str)
    
    def get_timestamp_from_stacktrace(self, stacktrace: str, get_min: bool = False, debug: bool = False):
        """
        Extract the earliest or latest timestamp from a stacktrace.
        
        Delegates to TimestampHandler for timestamp extraction logic.
        
        Args:
            stacktrace: The stacktrace text to analyze
            get_min: If True, returns the earliest timestamp; if False, returns the latest
            debug: If True, prints debug information during processing
        
        Returns:
            datetime: The earliest or latest timestamp found in the stacktrace
            None: If no valid timestamps are found
        """
        return self.timestamp_handler.get_timestamp_from_stacktrace(stacktrace, get_min, debug)

    # Wrapper functions for backward compatibility and clarity
    def get_min_timestamp_from_stacktrace(self, stacktrace: str, debug: bool = False):
        """
        Get the earliest timestamp from a stacktrace.
        
        Delegates to TimestampHandler for timestamp extraction logic.
        
        Args:
            stacktrace: The stacktrace text to analyze
            debug: If True, prints debug information
            
        Returns:
            datetime: The earliest timestamp found in the stacktrace
            None: If no valid timestamps are found
        """
        return self.timestamp_handler.get_min_timestamp_from_stacktrace(stacktrace, debug)

    def get_max_timestamp_from_stacktrace(self, stacktrace: str, debug: bool = False):
        """
        Get the latest timestamp from a stacktrace.
        
        Delegates to TimestampHandler for timestamp extraction logic.
        
        Args:
            stacktrace: The stacktrace text to analyze
            debug: If True, prints debug information
            
        Returns:
            datetime: The latest timestamp found in the stacktrace
            None: If no valid timestamps are found
        """
        return self.timestamp_handler.get_max_timestamp_from_stacktrace(stacktrace, debug)

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

    def remove_timestamps_from_stacktrace(self, stacktrace: str):
        """
        Remove timestamp patterns from a stacktrace to facilitate deduplication.
        
        Delegates to TimestampHandler for timestamp removal logic.
        
        Args:
            stacktrace: The stacktrace text to process
            
        Returns:
            tuple: A tuple containing:
                - str: The normalized stacktrace with timestamps replaced by placeholders
                - list: A list of tuples (start_pos, end_pos, timestamp) recording the
                  original positions and values of the timestamps
        """
        return self.timestamp_handler.remove_timestamps_from_stacktrace(stacktrace)

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
            except Exception as e:
                logger.error(f"Error processing log file {log_file_path}: {str(e)}")
                continue
        
        # Deduplicate stacktraces across all files
        unique_stacktraces = self.deduplicate_stacktraces(all_stacktraces)
        
        return unique_stacktraces
