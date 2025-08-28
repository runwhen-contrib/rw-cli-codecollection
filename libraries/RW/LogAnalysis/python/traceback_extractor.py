#!/usr/bin/env python3
"""
Traceback Extractor - Extract Python tracebacks from timestamped log files

This script extracts complete Python tracebacks from log files, handling:
- Standard tracebacks
- Exception chaining (caused by, during handling)
- Exception groups (Python 3.11+)
- PEP 657 enhanced tracebacks with precise error locations
- KeyboardInterrupt and other exceptions
- Multi-line exception messages
- Various timestamp formats
"""

import re
from typing import List, Tuple, Optional


class TimestampedTracebackExtractor:
    """Extracts Python tracebacks from timestamped log files."""
    
    def __init__(self):
        # Pattern to match the start of a traceback
        self.traceback_start_patterns = [
            re.compile(r'^(.*?)Traceback \(most recent call last\):'),
            re.compile(r'^(.*?)Exception Group Traceback \(most recent call last\):'),
        ]
        
        # Pattern to match exception chaining indicators
        self.chain_patterns = [
            re.compile(r'^(.+?)During handling of the above exception, another exception occurred:'),
            re.compile(r'^(.+?)The above exception was the direct cause of the following exception:'),
        ]
        
        # Pattern to match file references in traceback
        self.file_pattern = re.compile(r'^(.+?)  File "([^"]+)", line (\d+)(?:, in (.+))?')
        
        # Pattern to match the final exception line
        self.exception_pattern = re.compile(r'^(.+?)([A-Za-z_][A-Za-z0-9_.]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*(?:Group)?): (.*)$')
        
        # Pattern to match PEP 657 enhanced error indicators (~~~^ markers)
        self.pep657_pattern = re.compile(r'^(.+?)\s*[~^]+\s*$')
        
        # Pattern to match exception group sub-exception markers
        self.group_marker_pattern = re.compile(r'^(.+?)\s*[|+\-\s]*\d+\s*[|\-]+')
        
        # Common timestamp patterns (add more as needed)
        self.timestamp_patterns = [
            re.compile(r'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}[.,]\d{3})'),  # 2024-01-01 12:34:56.123
            re.compile(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[.,]\d{3}Z?)'),  # ISO format
            re.compile(r'^(\w{3} \d{1,2} \d{2}:\d{2}:\d{2})'),  # Jan 01 12:34:56
            re.compile(r'^(\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\])'),  # [2024-01-01 12:34:56]
        ]
    
    def extract_timestamp(self, line: str) -> Tuple[Optional[str], str]:
        """Extract timestamp from the beginning of a line."""
        for pattern in self.timestamp_patterns:
            match = pattern.match(line)
            if match:
                timestamp = match.group(1)
                remaining = line[len(timestamp):].strip()
                return timestamp, remaining
        return None, line.strip()
    
    def is_traceback_start(self, line: str) -> bool:
        """Check if line starts a traceback."""
        _, clean_line = self.extract_timestamp(line)
        return any(pattern.match(clean_line) for pattern in self.traceback_start_patterns)
    
    def is_chain_indicator(self, line: str) -> bool:
        """Check if line indicates exception chaining."""
        return any(pattern.match(line) for pattern in self.chain_patterns)
    
    def is_file_reference(self, line: str) -> bool:
        """Check if line is a file reference in traceback."""
        _, clean_line = self.extract_timestamp(line)
        return self.file_pattern.match(line) is not None
    
    def is_exception_line(self, line: str) -> bool:
        """Check if line is the final exception line."""
        _, clean_line = self.extract_timestamp(line)
        return self.exception_pattern.match(line) is not None
    
    def is_pep657_marker(self, line: str) -> bool:
        """Check if line contains PEP 657 enhanced error markers."""
        _, clean_line = self.extract_timestamp(line)
        return self.pep657_pattern.match(line) is not None
    
    def is_group_marker(self, line: str) -> bool:
        """Check if line is an exception group marker."""
        _, clean_line = self.extract_timestamp(line)
        return self.group_marker_pattern.match(line) is not None
    
    def is_continuation_line(self, line: str) -> bool:
        """
        Check if line could be a continuation of a traceback.
        This includes indented code lines, PEP 657 markers, group markers, etc.
        """
        _, clean_line = self.extract_timestamp(line)
        
        if not clean_line:
            return True  # Empty lines can be part of traceback
        
        # Check various continuation patterns
        return (
            clean_line.startswith('    ') or  # Indented code lines
            clean_line.startswith('  ') or   # File references and other indented content
            self.is_pep657_marker(line) or   # PEP 657 markers
            self.is_group_marker(line) or    # Exception group markers
            clean_line.startswith('|') or    # Exception group tree structure
            clean_line.startswith('+') or    # Exception group tree structure
            clean_line.startswith('-') or    # Exception group tree structure
            clean_line.startswith('^')       # PEP 657 caret indicators
        )
    
    def looks_like_new_log_entry(self, line: str) -> bool:
        """
        Heuristic to determine if a line starts a new log entry
        (and thus ends the current traceback).
        """
        timestamp, clean_line = self.extract_timestamp(line)
        
        # If we found a timestamp and the line doesn't look like traceback content
        if timestamp and not (
            self.is_traceback_start(line) or
            self.is_chain_indicator(line) or
            self.is_continuation_line(line)
        ):
            return True
        
        # Other heuristics for log entry start
        if clean_line.startswith('[') and ']' in clean_line[:50]:
            return True  # Likely log level or similar
        
        if any(level in clean_line[:20].upper() for level in ['DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL']):
            return True
        
        return False
    
    def extract_tracebacks_from_lines(self, lines: List[str]) -> List[str]:
        """Extract all tracebacks from a list of lines."""
        tracebacks = []
        i = 0
        
        while i < len(lines):
            line = lines[i]

            if self.is_traceback_start(line):
                traceback, end_idx = self._extract_single_traceback(lines, i)
                if traceback:
                    tracebacks.append(traceback)
                i = end_idx
            else:
                i += 1
        
        return tracebacks
    
    def _extract_single_traceback(self, lines: List[str], start_idx: int) -> Tuple[Optional[str], int]:
        """Extract a single traceback starting at start_idx."""
        traceback_lines = []
        current_idx = start_idx
        
        # Collect all lines belonging to this traceback
        while current_idx < len(lines):
            line = lines[current_idx]
            traceback_lines.append(line)
            current_idx += 1
            
            # Check if we've reached the end of the traceback
            if self._is_traceback_complete(traceback_lines):
                # Look ahead to see if there's exception chaining
                if current_idx < len(lines):
                    next_line = lines[current_idx]
                    if self.is_chain_indicator(next_line):
                        continue  # Continue collecting for chained exception
                    elif self.is_traceback_start(next_line):
                        # Another traceback immediately follows - might be chaining without explicit indicator
                        continue
                    elif not self.looks_like_new_log_entry(next_line) and self.is_continuation_line(next_line):
                        continue  # Multi-line exception message or other continuation
                
                break
            
            # Safety check: if we see a clear new log entry, stop
            if current_idx < len(lines) and self.looks_like_new_log_entry(lines[current_idx]):
                if self._has_exception_line(traceback_lines):
                    break  # We have a complete traceback
        
        if traceback_lines and self._is_valid_traceback(traceback_lines):
            content = '\n'.join(traceback_lines)
            return content, current_idx
        
        return None, current_idx
    
    def _is_traceback_complete(self, lines: List[str]) -> bool:
        """Check if the collected lines form a complete traceback."""
        return self._has_exception_line(lines)
    
    def _has_exception_line(self, lines: List[str]) -> bool:
        """Check if the lines contain an exception line."""
        for line in reversed(lines[-5:]):  # Check last few lines
            if self.is_exception_line(line):
                return True
        return False
    
    def _is_valid_traceback(self, lines: List[str]) -> bool:
        """Validate that the collected lines form a valid traceback."""
        if not lines:
            return False
        
        # Must start with traceback indicator
        if not any(self.is_traceback_start(line) for line in lines[:3]):
            return False
        
        # Should have an exception line
        return self._has_exception_line(lines)
    
    def extract_from_string(self, log_content: str) -> List[str]:
        """Extract tracebacks from a log string."""
        lines = log_content.split('\n')
        return self.extract_tracebacks_from_lines(lines)