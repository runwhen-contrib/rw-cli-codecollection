#!/usr/bin/env python3
"""
Main Traceback Extraction library class
"""

from robot.api.deco import keyword, library
from robot.api import logger
from typing import List, Union

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
    def extract_tracebacks(self, logs: str, fetch_most_recent: bool = False) -> Union[str, List[str]]:
        """
        Ingests deployment logs to extract tracebacks

        Args:
            deployment_logs: str
        Results:
            recent-most traceback, if fetch_most_recent = True
            list of tracebacks, otherwise
        """
        logs = str(logs) # safety conversion
        logs_list = logs.split("\n")

        logger.info(f"Obtained {len(logs_list)} lines for traceback extraction.\n")
        tracebacks: List[str] = []
        
        tracebacks.extend(self.python_traceback_extractor.extract_tracebacks_from_logs(logs_list))
        tracebacks.extend(self.java_traceback_extractor.extract_tracebacks_from_logs(logs_list))

        if fetch_most_recent:
            return "" if not tracebacks else tracebacks[-1]
        return tracebacks