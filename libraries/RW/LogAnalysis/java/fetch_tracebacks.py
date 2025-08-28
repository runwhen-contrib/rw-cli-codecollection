"""
Extract Java-Stacktraces from a given list of logs.
Log-string represents a dictionary(or a json), and hence starts and ends with curly-braces
"""

import re


# Pattern for DD-MM-YYYY HH:MM:SS.mmm at start of line
TIMESTAMP_PATTERN = r'^\d{2}-\d{2}-\d{4}\s\d{2}:\d{2}:\d{2}\.\d{3}'
JAVA_PATTERN = re.compile(r'^\s*at\s+[a-zA-Z_][\w$]*(\.[a-zA-Z_][\w$]*)+')


class JavaTracebackExtractor:
    def starts_with_timestamp(self, line) -> bool:
        """
        Check if a line starts with a timestamp in format: DD-MM-YYYY HH:MM:SS.mmm
        """
        if not line.strip():
            return False

        return bool(re.match(TIMESTAMP_PATTERN, line.strip()))

    def line_starts_with_at(self, log_line: str) -> bool:
        return JAVA_PATTERN.match(log_line) is not None

    def filter_logs_having_trace(self, logs: list[str]) -> list[str]:
        logs_with_stacktraces = []
        if isinstance(logs, list):
            for line in logs:
                line = str(line) # conversion to str for safety
                if "exception" in line.lower():
                    # potentially contains stacktrace
                    # if the line has the "at <method-path>" keyword, then the log is a java stacktrace
                    if any(self.line_starts_with_at(nested_log) for nested_log in line.split("\n")):
                        logs_with_stacktraces.append(line)
        return logs_with_stacktraces

    def extract_tracebacks_from_logs(self, logs: list[str]) -> list[str]:
        """
        Given a list of logs, extract JAVA stacktraces from them
        """
        # ensure we have a list of logs
        logs_as_str_list = []
        if isinstance(logs, list):
            logs_as_str_list = logs
        else:
            logs_as_str_list = [str(logs)]
        
        formatted_logs = []
        for line in logs_as_str_list:
            line = str(line) # conversion to str for safety
            if self.starts_with_timestamp(line):
                formatted_logs.append(line)
            else:
                if not formatted_logs:
                    formatted_logs.append(line)
                else:
                    formatted_logs[-1] += f'\n{line}'
        
        return self.filter_logs_having_trace(formatted_logs)    
