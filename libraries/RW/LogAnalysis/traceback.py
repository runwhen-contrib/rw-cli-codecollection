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
        # Handle new interface (logs_dir as directory path)
        if logs_dir is None and logs is None:
            logger.error("Either logs_dir or logs parameter must be provided")
            return [] if not fast_exit else ""
        
        if not os.path.exists(logs_dir):
            logger.error(f"Logs directory does not exist: {logs_dir}")
            return [] if not fast_exit else ""
        
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
        
        # Find all .txt files in the directory and subdirectories
        log_files = []
        for root, dirs, files in os.walk(logs_dir):
            for file in files:
                if file.endswith('.txt'):
                    log_files.append(os.path.join(root, file))
        
        logger.info(f"Found {len(log_files)} log files for traceback extraction.")
        
        tracebacks: Set[str] = set()
        
        
        # Process log files to extract tracebacks from both Python and Java
        extractors = [
            (self.python_traceback_extractor, "Python"),
            (self.java_traceback_extractor, "Java")
        ]
        
        for extractor, language in extractors:
            extracted_tracebacks = extractor.extract_tracebacks_from_log_files(log_files, fast_exit=fast_exit)
            if extracted_tracebacks:
                tracebacks.update(extracted_tracebacks)
                if fast_exit:
                    logger.info(f"Found {language} traceback in {log_files}, fast exit enabled")
                    return extracted_tracebacks[-1]
        
        tracebacks = list(tracebacks)
        logger.info(f"Extracted {len(tracebacks)} total unique tracebacks from {len(log_files)} files")
        
        if fast_exit:
            return "" if not tracebacks else tracebacks[-1]
        return tracebacks