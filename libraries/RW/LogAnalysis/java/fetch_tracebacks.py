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

    def extract_timestamp_from_line(self, line, return_position=False):
        """
        Extract timestamp from a line using the defined patterns.
        
        Args:
            line: The line to extract timestamp from
            return_position: If True, returns a tuple (timestamp, start, end)
        
        Returns:
            - If return_position=False: timestamp string or None
            - If return_position=True: tuple (timestamp, start, end) or (None, None, None)
        """
        line = line.strip()
        if not line:
            if return_position:
                return None, None, None
            else:
                return None
        
        # Find the first alphanumeric character
        first_alnum_pos = None
        for i, char in enumerate(line):
            if char.isalnum():
                first_alnum_pos = i
                break
        
        if first_alnum_pos is None:
            if return_position:
                return None, None, None
            else:
                return None
        
        # Check if timestamp pattern exists from that position
        remaining_line = line[first_alnum_pos:]
        
        for pattern in TIMESTAMP_PATTERNS:
            match = re.search(pattern, remaining_line)
            if match:
                timestamp = match.group(0)
                start, end = match.span()
                
                if return_position:
                    return timestamp, start, end
                else:
                    return timestamp
        
        # No timestamp found
        if return_position:
            return None, None, None
        else:
            return None

    def parse_timestamp_to_datetime(self, timestamp_str):
        """
        Parse timestamp string to datetime object using known patterns.
        Returns datetime object if successful, None otherwise.
        """
        if not timestamp_str:
            return None
        
        # Handle nanosecond precision in ISO timestamps by truncating to microseconds
        if 'T' in timestamp_str and timestamp_str.endswith('Z'):
            # Split at the decimal point
            parts = timestamp_str.rstrip('Z').split('.')
            if len(parts) == 2 and len(parts[1]) > 6:
                # Truncate to 6 digits (microseconds)
                timestamp_str = f"{parts[0]}.{parts[1][:6]}Z"
        
        # Define datetime patterns corresponding to timestamp patterns
        datetime_patterns = [
            '%d-%m-%Y %H:%M:%S.%f',  # DD-MM-YYYY HH:MM:SS.mmm
            '%Y-%m-%dT%H:%M:%S.%fZ', # ISO 8601: YYYY-MM-DDTHH:MM:SS.nnnnnnnZ
            '%Y-%m-%dT%H:%M:%S.%f',  # ISO 8601 without Z
            '%Y-%m-%d %H:%M:%S.%f'   # YYYY-MM-DD HH:MM:SS.nnn
        ]
        
        for pattern in datetime_patterns:
            try:
                return datetime.strptime(timestamp_str, pattern)
            except ValueError:
                continue
        
        return None
    
    def get_timestamp_from_stacktrace(self, stacktrace, get_min=False, debug=False):
        """
        Helper function to extract timestamp from a stacktrace.
        Works for both single-line and multi-line stacktraces.
        
        Args:
            stacktrace: The stacktrace to extract timestamp from
            get_min: If True, returns the minimum (earliest) timestamp
                    If False, returns the maximum (most recent) timestamp
            debug: If True, prints debug information
        
        Returns:
            datetime object if found, None otherwise
        """
        if not stacktrace:
            return None
        
        lines = stacktrace.split('\n') if '\n' in stacktrace else [stacktrace]
        result_datetime = None
        
        if debug:
            print(f"\n\tGetting {'min' if get_min else 'max'} timestamp from stacktrace: {stacktrace}\n")
        
        for line in lines:
            timestamp_str = self.extract_timestamp_from_line(line)
            if timestamp_str:
                dt = self.parse_timestamp_to_datetime(timestamp_str)
                if debug:
                    print(f"\n\tTimestamp string: {timestamp_str}\n"
                        f"\n\t\t->Parsed datetime: {dt}\n")
                if dt:
                    if result_datetime is None or (get_min and dt < result_datetime) or (not get_min and dt > result_datetime):
                        result_datetime = dt
        
        return result_datetime

    # Wrapper functions for backward compatibility and clarity
    def get_min_timestamp_from_stacktrace(self, stacktrace, debug=False):
        """Gets the minimum (earliest) timestamp from a stacktrace."""
        return self.get_timestamp_from_stacktrace(stacktrace, get_min=True, debug=debug)

    def get_max_timestamp_from_stacktrace(self, stacktrace, debug=False):
        """Gets the maximum (most recent) timestamp from a stacktrace."""
        return self.get_timestamp_from_stacktrace(stacktrace, get_min=False, debug=debug)

    def is_single_line_stacktrace(self, stacktrace):
        """Check if stacktrace is single-lined (no newline characters)."""
        return '\n' not in stacktrace.strip()

    def is_multi_line_stacktrace(self, stacktrace):
        """Check if stacktrace is multi-lined (contains newline characters)."""
        return '\n' in stacktrace.strip()

    def aggregate_java_stacktraces(self, stacktraces: list[str]) -> list[str]:
        """
        Aggregate Java stacktraces based on timestamp proximity.
        
        Updated Logic:
        - If i'th stacktrace has no timestamp: if multiline keep it and i++, if single line ignore it and i++
        - If i'th has timestamp but i+1'th doesn't:
        - If i'th is multiline: include i+1'th into i'th only if i+1'th is single line; if i+1'th is multiline store both separately and i+=2
        - If i'th is single line: simply add i+1'th to i'th and i+=2
        - If both have timestamps: compare and merge if < 1 minute difference
        - Return new aggregated list without modifying original
        """
        if not stacktraces:
            return stacktraces
        if len(stacktraces) == 1:
            # if multi-line stacktrace ==> retain, else return an empty list
            if self.is_multi_line_stacktrace(stacktraces[0]):
                return stacktraces
            else:
                return []
        
        results = stacktraces[:1]
        prev_stacktrace_ptr, next_stacktrace_ptr = 0, 1
        
        while next_stacktrace_ptr < len(stacktraces):
            current_stacktrace = results[prev_stacktrace_ptr]
            next_stacktrace = stacktraces[next_stacktrace_ptr]

            # print(f"\n{results}\n------------\n{next_stacktrace}\n\n", "$"*100)
            
            current_timestamp = self.get_max_timestamp_from_stacktrace(current_stacktrace)

            # next_timestamp should be min from next stacktrace
            next_timestamp = self.get_min_timestamp_from_stacktrace(next_stacktrace)

            is_current_stacktrace_single_line = self.is_single_line_stacktrace(current_stacktrace)
            is_current_stacktrace_multi_line = self.is_multi_line_stacktrace(current_stacktrace)
            is_next_stacktrace_single_line = self.is_single_line_stacktrace(next_stacktrace)
            is_next_stacktrace_multi_line = self.is_multi_line_stacktrace(next_stacktrace)

            # both stacktraces have no timestamp, OR
            # previous timestamp unavailable, next timestamp available ==> combine them and progress forward
            if current_timestamp is None:
                if next_timestamp and is_next_stacktrace_multi_line:
                    # print(f"\n\t\tcase-1/1: current stacktrace = {current_stacktrace}\n\t\tnext stacktrace = {next_stacktrace}\n")
                    results.append(next_stacktrace)
                else:
                    # print(f"\n\t\tcase-1/2: current_timestamp = {current_timestamp}, next_timestamp = {next_timestamp}, \n\t\tcurrent stacktrace = {current_stacktrace}\n\t\tnext stacktrace = {next_stacktrace}\n")
                    results[prev_stacktrace_ptr] += f"\n{next_stacktrace}"
                next_stacktrace_ptr += 1
                continue
            
            # previous timestamp available, next timestamp unavailable
            if current_timestamp and not next_timestamp:
                # print(f"\n\t\tcase-2: current stacktrace = {current_stacktrace}\n\t\tnext stacktrace = {next_stacktrace}\n")
                results[prev_stacktrace_ptr] += f"\n{next_stacktrace}"
                next_stacktrace_ptr += 1
                continue

            # both stacktraces have timestamps
            if current_timestamp and next_timestamp:

                # Both stacktraces have timestamps - check if they should be merged
                time_diff = abs((current_timestamp - next_timestamp).total_seconds())
                
                # If time difference is less than 1 minute (60 seconds), merge them
                if time_diff < 60:
                    # current is multi line, next is multi line
                    if is_current_stacktrace_multi_line and is_next_stacktrace_multi_line:
                        # print(f"\n\t\tcase-3/1: current stacktrace = {current_stacktrace}\n\t\tnext stacktrace = {next_stacktrace}\n")
                        results.append(next_stacktrace)
                        prev_stacktrace_ptr += 1
                        next_stacktrace_ptr += 1
                        continue
                    else:
                        # print(f"\n\t\tcase-3/2: current stacktrace = {current_stacktrace}\n\t\tnext stacktrace = {next_stacktrace}\n")
                        results[prev_stacktrace_ptr] += f"\n{next_stacktrace}"
                        next_stacktrace_ptr += 1
                        continue
                else:
                    # Time difference >= 1 minute, don't merge

                    # current is single-line stacktrace ==> remove current and add next
                    if is_current_stacktrace_single_line:
                        # print(f"\n\t\tcase-4/1: current stacktrace = {current_stacktrace}\n\t\tnext stacktrace = {next_stacktrace}\n")
                        # remove the current stacktrace as single-lined orphaned stacktraces are not useful
                        results.pop(-1)
                        results.append(next_stacktrace)
                        next_stacktrace_ptr += 1

                    # current is multi-line ==> add next and progress
                    elif is_current_stacktrace_multi_line:
                        # print(f"\n\t\tcase-4/2: current stacktrace = {current_stacktrace}\n\t\tnext stacktrace = {next_stacktrace}\n")
                        # add next stacktrace as the one after it could be useful
                        results.append(next_stacktrace)
                        prev_stacktrace_ptr += 1
                        next_stacktrace_ptr += 1
                
            if next_stacktrace_ptr == len(stacktraces):
                # last stacktrace got processed, check if prev_stacktrace_ptr is single-line, if so remove it
                if self.is_single_line_stacktrace(results[prev_stacktrace_ptr]):
                    results.pop(prev_stacktrace_ptr)

        return results

    def remove_timestamps_from_stacktrace(self, stacktrace):
        """
        Remove timestamp patterns from a stacktrace to facilitate deduplication.
        Returns a tuple of (stacktrace_without_timestamps, timestamp_positions)
        where timestamp_positions is a list of (start_pos, end_pos, timestamp) tuples.
        """
        if not stacktrace:
            return "", []
        
        # Split stacktrace into lines for processing
        lines = stacktrace.split('\n')
        normalized_lines = []
        timestamp_positions = []
        line_offset = 0
        
        for line in lines:
            # Use the enhanced extract_timestamp_from_line function
            timestamp, start, end = self.extract_timestamp_from_line(line, return_position=True)
            
            if timestamp:
                # Store the position and the timestamp
                timestamp_positions.append((line_offset + start, line_offset + end, timestamp))
                # Replace timestamp with a placeholder
                line = line[:start] + "TIMESTAMP_PLACEHOLDER" + line[end:]
            
            normalized_lines.append(line)
            line_offset += len(line) + 1  # +1 for the newline
        
        return '\n'.join(normalized_lines), timestamp_positions

    def deduplicate_stacktraces(self, stacktraces):
        """
        Deduplicate stacktraces by ignoring timestamp differences.
        Returns a list of unique stacktraces with their original timestamps.
        When duplicates are found, keeps the one with the latest timestamp.
        Results are sorted based on timestamp windows:
        - Non-overlapping windows are sorted chronologically
        - Overlapping windows are sorted by earliest start time
        """
        if not stacktraces:
            return []
        
        # Dictionary to store normalized stacktrace -> (original stacktrace, min_timestamp, max_timestamp) mapping
        unique_traces = {}
        
        for stacktrace in stacktraces:
            # Remove timestamps for comparison
            normalized, _ = self.remove_timestamps_from_stacktrace(stacktrace)
            
            # Get the min and max timestamps from this stacktrace
            min_timestamp = self.get_min_timestamp_from_stacktrace(stacktrace)
            max_timestamp = self.get_max_timestamp_from_stacktrace(stacktrace)
            
            # If this normalized trace is not yet in our unique traces, add it
            if normalized not in unique_traces:
                unique_traces[normalized] = (stacktrace, min_timestamp, max_timestamp)
            else:
                # If we already have this trace, check if the current one has a later timestamp
                _, existing_min, existing_max = unique_traces[normalized]
                
                # If current stacktrace has a later timestamp or existing has no timestamp, replace it
                if (max_timestamp and not existing_max) or \
                (max_timestamp and existing_max and max_timestamp > existing_max):
                    unique_traces[normalized] = (stacktrace, min_timestamp, max_timestamp)
        
        # Get the unique stacktraces with their timestamp windows
        unique_stacktraces_with_timestamps = [(trace, min_ts, max_ts) for trace, min_ts, max_ts in unique_traces.values()]
        
        # Define a custom sorting function based on timestamp windows
        def sort_by_timestamp_windows(item):
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
            print(f"\n\texception encountered while sorting stacktraces: {e}\n")
            sorted_stacktraces = unique_stacktraces_with_timestamps
        
        # Return just the original stacktraces in the sorted order
        return [trace for trace, _, _ in sorted_stacktraces]


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
        stacktrace_blocks = [[]]
        for line in logs:
            nested_logs = line.split("\n")
            unfiltered_nested_logs = [nested_log.strip().lstrip('-').lstrip('$') for nested_log in nested_logs]
            nested_logs = [nested_log for nested_log in unfiltered_nested_logs if nested_log]
            formatted_line = "\n".join(nested_logs)

            # Check if this log contains stacktrace frames
            at_lines = [nested_log for nested_log in nested_logs if self.line_starts_with_at(nested_log)]
            
            if "exception" in formatted_line.lower() and at_lines:
                # Complete stacktrace: has exception + stacktrace frames
                # stacktraces.append(formatted_line)
                stacktrace_blocks[-1].append(formatted_line)
            elif len(at_lines) >= 1:
                # Standalone stacktrace frames: any "at" lines (could be truncated stacktrace)
                # stacktraces.append(formatted_line)
                stacktrace_blocks[-1].append(formatted_line)
            else:
                # end of block formation, after this new block should start
                stacktrace_blocks.append([])

        # print(f"\n\tStacktrace blocks: \n{stacktrace_blocks}\n")

        stacktraces = []
        for block in stacktrace_blocks:
            stacktraces.extend(self.aggregate_java_stacktraces(block))

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
            line = line.strip()
            if self.has_timestamp_at_alphanumeric_start(line):
                actual_logs.append(line)
            else:
                if not actual_logs:
                    actual_logs.append(line)
                else:
                    actual_logs[-1] += f'\n{line}'
        
        return self.filter_logs_having_trace(actual_logs)

    def extract_tracebacks_from_logs_dir(self, log_files: list[str]) -> list[str]:
        """
        Extract Java stacktraces from a given directory of logs.
        """
        total_stacktraces = []
        for log_file in log_files:
            try:
                with open(log_file, 'r', encoding='utf-8', errors='ignore') as f:
                    logs_list = []
                    for line in f:
                        logs_list.append(line.rstrip('\n'))
                curr_file_java_stacktraces = self.extract_tracebacks_from_logs(logs_list)
                total_stacktraces.extend(curr_file_java_stacktraces)
            except Exception as e:
                logger.error(f"Error processing log file {log_file}: {str(e)}")
                continue
        unique_stacktraces = self.deduplicate_stacktraces(total_stacktraces)

        print(f"\nFound {len(total_stacktraces)} total stacktraces, {len(unique_stacktraces)} unique stacktraces after deduplication\n")
    
        # Print the unique stacktraces
        print(f"\n{'-'*150}\n".join(unique_stacktraces))

        return unique_stacktraces
