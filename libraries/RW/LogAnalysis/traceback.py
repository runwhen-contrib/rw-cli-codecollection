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
    def extract_tracebacks(self, logs_dir: str = None, logs: str = None, fast_exit: bool = False) -> Union[str, List[str]]:
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
        # Handle legacy interface (logs as string)
        if logs is not None:
            logs_str = str(logs)  # safety conversion
            logs_list = logs_str.split("\n")
            
            logger.info(f"Obtained {len(logs_list)} lines for traceback extraction (legacy mode).")
            tracebacks: Set[str] = set()
            
            tracebacks.update(self.python_traceback_extractor.extract_tracebacks_from_logs(logs_list))
            tracebacks.update(self.java_traceback_extractor.extract_tracebacks_from_logs(logs_list))
            
            if fast_exit:
                return "" if not tracebacks else list(tracebacks)[-1]
            return list(tracebacks)
        
        # Handle new interface (logs_dir as directory path)
        if logs_dir is None:
            logger.error("Either logs_dir or logs parameter must be provided")
            return [] if not fast_exit else ""
        
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
        
        tracebacks: Set[str] = set()
        
        
        # Process each log file for python stacktraces
        for log_file in log_files:
            try:
                with open(log_file, 'r', encoding='utf-8', errors='ignore') as f:
                    logs_list = []
                    for line in f:
                        logs_list.append(line.rstrip('\n'))

                logger.info(f"Processing {log_file} with {len(logs_list)} lines")
                
                # Extract Python tracebacks
                python_tracebacks = self.python_traceback_extractor.extract_tracebacks_from_logs(logs_list)
                if python_tracebacks:
                    tracebacks.update(python_tracebacks)
                    if fast_exit:
                        logger.info(f"Found Python traceback in {log_file}, fast exit enabled")
                        return python_tracebacks[-1]                        
            except Exception as e:
                logger.error(f"Error processing log file {log_file}: {str(e)}")
                continue

        # process the logs_dir directly to extract JAVA stacktraces
        java_stacktraces = self.java_traceback_extractor.extract_tracebacks_from_logs_dir(log_files)
        if java_stacktraces:
            tracebacks.update(java_stacktraces)
            if fast_exit:
                logger.info(f"Found Java stacktrace in {log_files}, fast exit enabled")
                return java_stacktraces[-1]
        
        tracebacks = list(tracebacks)
        logger.info(f"Extracted {len(tracebacks)} total unique tracebacks from {len(log_files)} files")
        
        if fast_exit:
            return "" if not tracebacks else tracebacks[-1]
        return tracebacks