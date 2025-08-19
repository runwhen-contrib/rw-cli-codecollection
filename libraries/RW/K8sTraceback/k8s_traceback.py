#!/usr/bin/env python3
"""
"""

import json
import traceback

from robot.api.deco import keyword, library
from robot.api import logger
from robot.libraries.BuiltIn import BuiltIn
from typing import List

from .k8s_tb_utils import longest_balanced_curlies_sequence

@library(scope='GLOBAL', auto_keywords=True, doc_format='reST')
class K8sTraceback:
    """
    K8s Traceback Extraction Library
    
    This library provides a keyword for extracting tracebacks from Kubernetes pod logs.
    """

    def __init__(self):
        self.ROBOT_LIBRARY_SCOPE = 'GLOBAL'

    @keyword
    def extract_tracebacks(self, deployment_logs: List[str]) -> List[str]:
        """
        Ingests deployment logs to extract tracebacks

        Args:
            deployment_logs: str
        Results:
            traceback-only logs
            TODO: make this into a list of strs
        """
        # TODO: add a logger.info instead
        logger.info(f"obtained {len(deployment_logs)} lines in extract_tracebacks.\n")
        tracebacks = []
        try:
            n_dicts, n_exceptions, n_not_dicts, n_dicts_with_event_msgs = 0, 0, 0, 0
            excp_messages = set()
            for dp_log in deployment_logs:
                if dp_log.startswith('{'):
                    try:
                        dp_log_json_obj = json.loads(dp_log)
                        if isinstance(dp_log_json_obj, dict):
                            n_dicts += 1
                        event_msg = dp_log_json_obj.get("event", "")
                        if event_msg:
                            if "error handling" in event_msg:
                                n_dicts_with_event_msgs += 1
                                # the error/stacktrace content begins with "with data {...}"
                                traceback_dict_start_idx = event_msg.find("with data {")
                                traceback_dict_str_temp = event_msg[traceback_dict_start_idx+len("with data "):]
                                tb_dict_str_start, tb_dict_str_end = longest_balanced_curlies_sequence(traceback_dict_str_temp)
                                if tb_dict_str_start != -1 and tb_dict_str_end != -1:
                                    tb_dict_str = traceback_dict_str_temp[tb_dict_str_start:tb_dict_str_end]
                                    try:
                                        tb_dict = json.loads(tb_dict_str)
                                        stacktrace_str = tb_dict.get("stacktrace", "")
                                        if stacktrace_str:
                                            tracebacks.append(stacktrace_str)
                                    except Exception as tb_dict_parse_excp:
                                        # append this as a exception str
                                        # report this to the exception block of tracebacks
                                        pass
                    except Exception as excp:
                        n_exceptions += 1
                        excp_messages.add(''.join(traceback.format_exception(type(excp), excp, excp.__traceback__)))
                        continue
                else:
                    n_not_dicts += 1
        except Exception as excp:
            pass

        return tracebacks
