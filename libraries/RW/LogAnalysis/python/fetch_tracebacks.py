"""
Extract Python-Tracebacks from a given log-string.
Log-string represents a dictionary(or a json), and hence starts and ends with curly-braces
"""

import json
from typing import List

from robot.api import logger

from .traceback_extractor import TimestampedTracebackExtractor
from .tb_utils import longest_balanced_curlies_sequence


class PythonTracebackExtractor:
    def __init__(self):
        self.timestamped_log_tb_extractor = TimestampedTracebackExtractor()

    def extract_traceback_from_dict_log(self, log_str: str) -> List[str]:
        """
        Given a log string, extract logs from it.
        this assumes the log string is actually a jsonified string.
        this was designed keeping logs of platform in mind.
        """
        tracebacks = []
        try:
            log_str_json_obj = json.loads(log_str)
            if isinstance(log_str_json_obj, dict):
                # log statement is of type {"event": "some message containing data {"exception": "exception message", "stacktrace": "full stacktrace"...}", ...}
                event_msg = log_str_json_obj.get("event", "")
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
                                timestamp = log_str_json_obj.get("timestamp", "")
                                full_tb_str = f"Traceback time:{timestamp}\n\n" if timestamp else ""
                                full_tb_str += stacktrace_str
                                tracebacks.append(full_tb_str)
                        except Exception as tb_dict_parse_excp:
                            # TODO: decide if the following is needed/relevant
                            # append this as a exception str
                            # report this to the exception block of tracebacks
                            logger.error(f"Exception while parsing tb_dict_str: \n{tb_dict_str}\n{tb_dict_parse_excp}")
                            
                            # TODO: if tracebacks are reported, runner-worker may start to have too many tracebacks leading to a traceback SLI alert.
                            # logger.error(''.join(traceback.format_exception(type(tb_dict_parse_excp), tb_dict_parse_excp, tb_dict_parse_excp.__traceback__)))

                            # check if tb_dict_str has traceback patterns and store'em
                            curr_log_tracebacks = self.timestamped_log_tb_extractor.extract_from_string(tb_dict_str)
                            if curr_log_tracebacks:
                                tracebacks.extend(curr_log_tracebacks)
                    else:
                        # check if traceback_dict_str_temp has traceback patterns and store'em
                        curr_log_tracebacks = self.timestamped_log_tb_extractor.extract_from_string(traceback_dict_str_temp)
                        if curr_log_tracebacks:
                            tracebacks.extend(curr_log_tracebacks)
                else:
                    # check if event_msg has traceback patterns and store'em
                    curr_log_tracebacks = self.timestamped_log_tb_extractor.extract_from_string(event_msg)
                    if curr_log_tracebacks:
                        tracebacks.extend(curr_log_tracebacks)
            else:
                # check if log_str_json_obj has traceback patterns and store'em
                curr_log_tracebacks = self.timestamped_log_tb_extractor.extract_from_string(log_str_json_obj)
                if curr_log_tracebacks:
                    tracebacks.extend(curr_log_tracebacks)
        except Exception as excp:
            # BuiltIn().log_to_console(f"\n{''.join(traceback.format_exception(type(excp), excp, excp.__traceback__))}\n")
            
            # check if log_str has traceback patterns and store'em
            curr_log_tracebacks = self.timestamped_log_tb_extractor.extract_from_string(log_str)
            if curr_log_tracebacks:
                tracebacks.extend(curr_log_tracebacks)
        
        return tracebacks
    
    def extract_traceback_from_string_log(self, log_str: str) -> List[str]:
        """
        Given a log string, extract logs from it.
        this assumes the log string begins with a timestamp, followed by the log message.
        """
        return self.timestamped_log_tb_extractor.extract_from_string(log_str)
    
    def extract_tracebacks_from_logs(self, logs: list[str]) -> list[str]:
        """
        Given a list of logs, extract Python stacktraces from them
        """
        tracebacks = []
        if isinstance(logs, list):
            for dp_log in logs:
                if dp_log.startswith('{'):
                    tracebacks.extend(self.extract_traceback_from_dict_log(dp_log))
        else:
            logs = str(logs)
            # check if logs has traceback patterns and store'em
            curr_log_tracebacks = self.timestamped_log_tb_extractor.extract_from_string(logs)
            if curr_log_tracebacks:
                tracebacks.extend(curr_log_tracebacks)
        return tracebacks