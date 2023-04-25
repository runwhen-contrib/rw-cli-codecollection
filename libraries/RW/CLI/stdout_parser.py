"""
CLI Generic keyword library for running and parsing CLI stdout

Scope: Global
"""
import re, logging
from RW import platform
from RW.Core import Core

from .cli_utils import *

ROBOT_LIBRARY_SCOPE = "GLOBAL"


logger = logging.getLogger(__name__)

RECOGNIZED_STDOUT_PARSE_QUERIES = [
    "raise_issue_if_eq",
    "raise_issue_if_neq",
    "raise_issue_if_lt",
    "raise_issue_if_gt",
    "raise_issue_if_contains",
    "raise_issue_if_ncontains",
]


def parse_cli_output_by_line(
    rsp: platform.ShellServiceResponse,
    lines_like_regexp,
    set_severity_level: int = 4,
    set_issue_expected: str = "",
    set_issue_actual: str = "",
    set_issue_reproduce_hint: str = "",
    set_issue_title: str = "",
    expected_rsp_statuscodes: list[int] = [200],
    expected_rsp_returncodes: list[int] = [0],
    contains_stderr_ok: bool = True,
    raise_issue_if_no_groups_found: bool = True,
    **kwargs,
) -> int:
    _core: Core = Core()
    issue_count: int = 0
    logger.info(f"stdout: {rsp.stdout}")
    logger.info(lines_like_regexp)
    logger.info(f"kwargs: {kwargs}")
    if not contains_stderr_ok and rsp.stderr:
        raise ValueError(f"rsp {rsp} contains unexpected stderr {rsp.stderr}")
    if rsp.status not in expected_rsp_statuscodes:
        raise ValueError(f"rsp {rsp} has unexpected HTTP status {rsp.status}")
    if rsp.returncode not in expected_rsp_returncodes:
        raise ValueError(f"rsp {rsp} has unexpected shell return code {rsp.returncode}")
    stdout: str = rsp.stdout
    logger.info(rsp.stdout.split("\n"))
    for line in rsp.stdout.split("\n"):
        if not line:
            continue
        capture_grps = None
        regexp_results = re.match(rf"{lines_like_regexp}", line)
        if regexp_results:
            regexp_results = regexp_results.groupdict()
        logger.info(f"regexp results: {regexp_results}")
        if not regexp_results or len(regexp_results.keys()) == 0:
            _core.add_issue(
                set_severity_level,
                "No Capture Groups Found With Supplied Regex",
                f"Expected to create capture groups from line: {line} using regexp: {lines_like_regexp}",
                f"Actual result: {regexp_results}",
                f"Try apply the regex: {lines_like_regexp} to lines produced by the command: {rsp.parsed_cmd}",
            )
            issue_count += 1
            continue
        parse_queries = kwargs
        capture_groups = regexp_results
        # Always allow direct parsing of the line as a capture group named _line
        capture_groups["_line"] = line
        for parse_query, query_value in parse_queries.items():
            query_parts = parse_query.split("__")
            if len(query_parts) != 2:
                logger.warning(f"Could not parse query: {parse_query}")
                continue
            prefix = query_parts[0]
            query = query_parts[1]
            logger.info(f"Got prefix: {prefix} and query: {query}")
            if query not in RECOGNIZED_STDOUT_PARSE_QUERIES:
                logger.info(f"Query {query} not in recognized list: {RECOGNIZED_STDOUT_PARSE_QUERIES}")
                continue
            if prefix in capture_groups.keys():
                numeric_castable: bool = False
                capture_group_value = capture_groups[prefix]
                # precompare cast
                if query in ["raise_issue_if_gt", "raise_issue_if_lt"]:
                    try:
                        query_value = float(query_value)
                        capture_group_value = float(capture_group_value)
                        numeric_castable = True
                    except Exception as e:
                        logger.warning(
                            f"Numeric parse query requested but values not castable: {query_value} and {capture_group_value}"
                        )
                if query == "raise_issue_if_eq" and query_value == capture_group_value:
                    _core.add_issue(
                        severity=set_severity_level,
                        title="Detected Exact Error Value in Output" if not set_issue_title else set_issue_title,
                        expected=f"The parsed output {line} with regex: {lines_like_regexp} with the capture group: {prefix} should not be equal to {capture_group_value}"
                        if not set_issue_expected
                        else set_issue_expected,
                        actual=f"The parsed output {line} with regex: {lines_like_regexp} contains {prefix}=={capture_group_value} and should not be equal to {capture_group_value}"
                        if not set_issue_actual
                        else set_issue_actual,
                        reproduce_hint=f"Run {rsp.cmd} and apply the regex {lines_like_regexp} per line"
                        if not set_issue_reproduce_hint
                        else set_issue_reproduce_hint,
                    )
                    issue_count += 1
                elif query == "raise_issue_if_neq" and query_value != capture_group_value:
                    _core.add_issue(
                        severity=set_severity_level,
                        title="Unexpected Value in Output" if not set_issue_title else set_issue_title,
                        expected=f"The parsed output {line} with regex: {lines_like_regexp} with the capture group: {prefix} should be equal to {capture_group_value}"
                        if not set_issue_expected
                        else set_issue_expected,
                        actual=f"The parsed output {line} with regex: {lines_like_regexp} does not contain the expected value of: {prefix}=={capture_group_value}"
                        if not set_issue_actual
                        else set_issue_actual,
                        reproduce_hint=f"Run {rsp.cmd} and apply the regex {lines_like_regexp} per line"
                        if not set_issue_reproduce_hint
                        else set_issue_reproduce_hint,
                    )
                    issue_count += 1
                elif query == "raise_issue_if_lt" and numeric_castable and capture_group_value < query_value:
                    _core.add_issue(
                        severity=set_severity_level,
                        title="Parsed Value Below Allowed Amount" if not set_issue_title else set_issue_title,
                        expected=f"The parsed output {line} with regex: {lines_like_regexp} should have a value >= {query_value}"
                        if not set_issue_expected
                        else set_issue_expected,
                        actual=f"The parsed output {line} with regex: {lines_like_regexp} found value: {capture_group_value} and it's less than {query_value}"
                        if not set_issue_actual
                        else set_issue_actual,
                        reproduce_hint=f"Run {rsp.cmd} and apply the regex {lines_like_regexp} per line"
                        if not set_issue_reproduce_hint
                        else set_issue_reproduce_hint,
                    )
                    issue_count += 1
                elif query == "raise_issue_if_gt" and numeric_castable and capture_group_value > query_value:
                    _core.add_issue(
                        severity=set_severity_level,
                        title="Parsed Value Above Allowed Amount" if not set_issue_title else set_issue_title,
                        expected=f"The parsed output {line} with regex: {lines_like_regexp} should have a value <= {query_value}"
                        if not set_issue_expected
                        else set_issue_expected,
                        actual=f"The parsed output {line} with regex: {lines_like_regexp} found value: {capture_group_value} and it's greater than {query_value}"
                        if not set_issue_actual
                        else set_issue_actual,
                        reproduce_hint=f"Run {rsp.cmd} and apply the regex {lines_like_regexp} per line"
                        if not set_issue_reproduce_hint
                        else set_issue_reproduce_hint,
                    )
                    issue_count += 1
                elif query == "raise_issue_if_contains" and query_value in capture_group_value:
                    _core.add_issue(
                        severity=set_severity_level,
                        title="Parsed Output Contains an Error Value" if not set_issue_title else set_issue_title,
                        expected=f"The parsed output {line} with regex: {lines_like_regexp} resulted in {capture_group_value} and should not contain {query_value}"
                        if not set_issue_expected
                        else set_issue_expected,
                        actual=f"The parsed output {line} with regex: {lines_like_regexp} resulted in {capture_group_value} and it contains {query_value} when it should not"
                        if not set_issue_actual
                        else set_issue_actual,
                        reproduce_hint=f"Run {rsp.cmd} and apply the regex {lines_like_regexp} per line"
                        if not set_issue_reproduce_hint
                        else set_issue_reproduce_hint,
                    )
                    issue_count += 1
                elif query == "raise_issue_if_ncontains" and query_value not in capture_group_value:
                    _core.add_issue(
                        severity=set_severity_level,
                        title="Parsed Output Does Not Contain Expected Value"
                        if not set_issue_title
                        else set_issue_title,
                        expected=f"The parsed output {line} with regex: {lines_like_regexp} resulted in {capture_group_value} and should contain {query_value}"
                        if not set_issue_expected
                        else set_issue_expected,
                        actual=f"The parsed output {line} with regex: {lines_like_regexp} resulted in {capture_group_value} and we expected to find {query_value} in the result"
                        if not set_issue_actual
                        else set_issue_actual,
                        reproduce_hint=f"Run {rsp.cmd} and apply the regex {lines_like_regexp} per line"
                        if not set_issue_reproduce_hint
                        else set_issue_reproduce_hint,
                    )
                    issue_count += 1
            else:
                logger.info(f"Prefix {prefix} not found in capture groups: {capture_groups.keys()}")
                continue
    return issue_count
