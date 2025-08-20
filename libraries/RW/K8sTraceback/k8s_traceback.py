#!/usr/bin/env python3
"""
"""

import json
import traceback

from robot.api.deco import keyword, library
from robot.api import logger
from robot.libraries.BuiltIn import BuiltIn
from typing import List, Union

from .k8s_tb_utils import longest_balanced_curlies_sequence
from .k8s_traceback_extractor import TracebackExtractor

@library(scope='GLOBAL', auto_keywords=True, doc_format='reST')
class K8sTraceback:
    """
    K8s Traceback Extraction Library
    
    This library provides a keyword for extracting tracebacks from Kubernetes pod logs.
    """

    def __init__(self):
        self.ROBOT_LIBRARY_SCOPE = 'GLOBAL'
        self.traceback_extractor = TracebackExtractor()

    @keyword
    def extract_tracebacks(self, deployment_logs: List[str], fetch_most_recent: bool = False) -> Union[str, List[str]]:
        """
        Ingests deployment logs to extract tracebacks

        Args:
            deployment_logs: str
        Results:
            recent-most traceback, if fetch_most_recent = True
            list of tracebacks, otherwise
        """
        logger.info(f"Obtained {len(deployment_logs)} lines for traceback extraction.\n")
        BuiltIn().log_to_console(f"Obtained {len(deployment_logs)} lines for traceback extraction.\n")
        n_logs = len(deployment_logs)
        n_dicts, n_non_dicts, n_exceptions = 0, 0, 0
        tracebacks: List[str] = []
        if isinstance(deployment_logs, list):
            for dp_log in deployment_logs:
                if dp_log.startswith('{'):
                    try:
                        dp_log_json_obj = json.loads(dp_log)
                        if isinstance(dp_log_json_obj, dict):
                            n_dicts += 1
                            # log statement is of type {"event": "some message containing data {"exception": "exception message", "stacktrace": "full stacktrace"...}", ...}
                            event_msg = dp_log_json_obj.get("event", "")
                            if event_msg and all(tb_pattern in event_msg for tb_pattern in ["error handling", "with data {"]):
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
                                            # TODO: decide if timestamp should also be supplied, might be useful for dedup
                                            timestamp = dp_log_json_obj.get("timestamp", "")
                                            full_tb_str = f"Traceback time:{timestamp}\n\n" if timestamp else ""
                                            full_tb_str += stacktrace_str
                                            tracebacks.append(full_tb_str)
                                    except Exception as tb_dict_parse_excp:
                                        # TODO: decide if the following is needed/relevant
                                        # append this as a exception str
                                        # report this to the exception block of tracebacks
                                        logger.error(f"Exception while parsing tb_dict_str: \n{tb_dict_str}\n{tb_dict_parse_excp}")
                                        BuiltIn().log_to_console(f"Exception while parsing tb_dict_str: \n{tb_dict_str}\n{tb_dict_parse_excp}")
                                        
                                        # TODO: if tracebacks are reported, runner-worker may start to have too many tracebacks leading to a traceback SLI alert.
                                        # logger.error(''.join(traceback.format_exception(type(tb_dict_parse_excp), tb_dict_parse_excp, tb_dict_parse_excp.__traceback__)))

                                        # check if tb_dict_str has traceback patterns and store'em
                                        curr_log_tracebacks = self.traceback_extractor.extract_from_string(tb_dict_str)
                                        if curr_log_tracebacks:
                                            tracebacks.extend(curr_log_tracebacks)
                                else:
                                    # check if traceback_dict_str_temp has traceback patterns and store'em
                                    curr_log_tracebacks = self.traceback_extractor.extract_from_string(traceback_dict_str_temp)
                                    if curr_log_tracebacks:
                                        tracebacks.extend(curr_log_tracebacks)
                            else:
                                # check if event_msg has traceback patterns and store'em
                                curr_log_tracebacks = self.traceback_extractor.extract_from_string(event_msg)
                                if curr_log_tracebacks:
                                    tracebacks.extend(curr_log_tracebacks)
                        else:
                            # check if dp_log_json_obj has traceback patterns and store'em
                            curr_log_tracebacks = self.traceback_extractor.extract_from_string(dp_log_json_obj)
                            if curr_log_tracebacks:
                                tracebacks.extend(curr_log_tracebacks)
                    except Exception as excp:
                        n_exceptions += 1
                        BuiltIn().log_to_console(f"\n{''.join(traceback.format_exception(type(excp), excp, excp.__traceback__))}\n")
                        # check if dp_log has traceback patterns and store'em
                        curr_log_tracebacks = self.traceback_extractor.extract_from_string(dp_log)
                        if curr_log_tracebacks:
                            tracebacks.extend(curr_log_tracebacks)
                else:
                    n_non_dicts += 1
                    if 'trace' in dp_log:
                        BuiltIn().log_to_console(f"\n{'-'*150}\n{dp_log}\n{'-'*150}\n")
                    # log line not a dictionary, it mostly starts with a timestamp followed by the log line
                    # check if dp_log has traceback patterns and store'em
                    curr_log_tracebacks = self.traceback_extractor.extract_from_string(dp_log)
                    if curr_log_tracebacks:
                        tracebacks.extend(curr_log_tracebacks)
        else:
            if isinstance(deployment_logs, str):
                # check if deployment_logs has traceback patterns and store'em
                curr_log_tracebacks = self.traceback_extractor.extract_from_string(deployment_logs)
                if curr_log_tracebacks:
                    tracebacks.extend(curr_log_tracebacks)
        BuiltIn().log_to_console(f"\nn_logs = {n_logs}, n_dicts = {n_dicts}, n_exceptions = {n_exceptions}, n_non_dicts = {n_non_dicts}\n")

        if fetch_most_recent:
            return "" if not tracebacks else tracebacks[-1]
        return tracebacks