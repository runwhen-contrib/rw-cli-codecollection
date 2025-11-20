#!/usr/bin/env python3
"""
Main Traceback Extraction library class

Author: akshayrw25
"""

import os
import glob
from robot.api.deco import keyword, library
from robot.api import logger
from typing import List, Union, Set
from datetime import datetime

from .python.fetch_tracebacks import PythonTracebackExtractor
from .java.fetch_tracebacks import JavaTracebackExtractor


@library(scope='GLOBAL', auto_keywords=True, doc_format='reST')
class ExtractTraceback:
    """
    Traceback Extraction Library
    
    This library provides a keyword for extracting tracebacks from any set of given logs.
    """

    def __init__(self):
        self.ROBOT_LIBRARY_SCOPE = 'GLOBAL'
        self.python_traceback_extractor = PythonTracebackExtractor()
        self.java_traceback_extractor = JavaTracebackExtractor()

    @keyword
    def extract_logs_from_logs_dir(self, logs_dir: str) -> str:
        """
        Ingests log content from a directory and returns a string of all the logs
        """
         # Handle new interface (logs_dir as directory path)
        if logs_dir is None:
            logger.error("logs_dir must be provided")
            return ""
        
        if not os.path.exists(logs_dir):
            logger.error(f"Logs directory does not exist: {logs_dir}")
            return ""
        
        log_files = []
        for root, dirs, files in os.walk(logs_dir):
            for file in files:
                if file.endswith('.txt'):
                    log_files.append(os.path.join(root, file))
        
        all_logs = f"{'='*50}\tLOG LINES\t{'='*50}\n"
        
        # Process each log file
        for log_file_path in log_files:
            try:
                # Read the log file line by line
                with open(log_file_path, 'r', encoding='utf-8', errors='ignore') as file:
                    log_lines = [line.rstrip('\n') for line in file]
                all_logs += f"\t{'-'*40} {log_file_path.strip()} {'-'*40}\n" + "\n".join(log_lines) + "\n"
            except Exception as _:
                continue
        
        return all_logs

    def _parse_ts(self, ts) -> datetime:
        """
        Best-effort parsing of timestamps that may already be datetime objects,
        ISO formatted strings, or epoch values. Falls back to datetime.min when
        parsing fails so comparisons remain stable.
        """
        if isinstance(ts, datetime):
            return ts
        if ts is None:
            return datetime.min
        # Allow epoch integers/floats
        if isinstance(ts, (int, float)):
            try:
                return datetime.fromtimestamp(ts)
            except (ValueError, OSError):
                return datetime.min
        ts_str = str(ts)
        try:
            return datetime.fromisoformat(ts_str)
        except ValueError:
            return datetime.min

    def _deduplicate_tracebacks(self, tracebacks: List[dict]) -> List[dict]:
        latest_by_stacktrace = {}
        for tb in tracebacks:
            st = tb["stacktrace"]
            if st not in latest_by_stacktrace:
                latest_by_stacktrace[st] = tb
            else:
                if self._parse_ts(tb["timestamp"]) > self._parse_ts(latest_by_stacktrace[st]["timestamp"]):
                    latest_by_stacktrace[st] = tb
        return list(latest_by_stacktrace.values())

    @keyword
    def extract_tracebacks(self, logs_dir: str = None, logs: str = None, fast_exit: bool = False) -> Union[dict, List[dict]]:
        """
        Ingests deployment logs from a directory or log string to extract tracebacks

        Args:
            logs_dir: str - Path to directory containing log files (new interface)
            logs: str - Log content as string (legacy interface)
            fast_exit: bool - If True, returns the first traceback found and stops processing
        Results:
            recent-most traceback, if fast_exit = True
            list of unique tracebacks, otherwise
        """
        # Handle new interface (logs_dir as directory path)
        if logs_dir is None and logs is None:
            logger.error("Either logs_dir or logs parameter must be provided")
            return [] if not fast_exit else ""
        
        # Handle legacy interface (logs as string)
        if logs is not None:
            logs_str = str(logs)  # safety conversion
            logs_list = logs_str.split("\n")
            
            logger.info(f"Obtained {len(logs_list)} lines for traceback extraction (legacy mode).")
            tracebacks: List[dict] = []
            
            tracebacks.extend(self.python_traceback_extractor.extract_tracebacks_from_logs(logs_list))
            tracebacks.extend(self.java_traceback_extractor.extract_tracebacks_from_logs(logs_list))

            unique_tracebacks = self._deduplicate_tracebacks(tracebacks)

            if fast_exit:
                return "" if not unique_tracebacks else unique_tracebacks[-1]
            return unique_tracebacks

        # Handle new interface (logs_dir as directory path)
        if not os.path.exists(logs_dir):
            logger.error(f"Logs directory does not exist: {logs_dir}")
            return [] if not fast_exit else ""
        
        # Find all .txt files in the directory and subdirectories
        log_files = []
        for root, dirs, files in os.walk(logs_dir):
            for file in files:
                if file.endswith('.txt'):
                    log_files.append(os.path.join(root, file))
        
        logger.info(f"Found {len(log_files)} log files for traceback extraction.")
        
        tracebacks: List[dict] = []
        
        
        # Process log files to extract tracebacks from both Python and Java
        extractors = [
            (self.python_traceback_extractor, "Python"),
            (self.java_traceback_extractor, "Java")
        ]
        
        unique_tracebacks: List[dict] = []
        for extractor, language in extractors:
            extracted_tracebacks = extractor.extract_tracebacks_from_log_files(log_files, fast_exit=fast_exit)
            if extracted_tracebacks:
                tracebacks.extend(extracted_tracebacks)
                unique_tracebacks = self._deduplicate_tracebacks(tracebacks)
                if fast_exit:
                    logger.info(f"Found {language} traceback in {log_files}, fast exit enabled")
                    return unique_tracebacks[-1]
        
        logger.info(f"Extracted {len(unique_tracebacks)} total unique tracebacks from {len(log_files)} files")
        
        if fast_exit:
            return "" if not unique_tracebacks else unique_tracebacks[-1]
        return unique_tracebacks