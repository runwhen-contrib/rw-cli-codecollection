"""
CLI Generic keyword library for running and parsing CLI stdout

Scope: Global
"""
import re, logging
from string import Template
from datetime import datetime, timezone
from typing import List, Dict
from RW import platform
from RW.Core import Core

from . import cli_utils

ROBOT_LIBRARY_SCOPE = "GLOBAL"


logger = logging.getLogger(__name__)

MAX_ISSUE_STRING_LENGTH: int = 1920

RECOGNIZED_STDOUT_PARSE_QUERIES = [
    "raise_issue_if_eq",
    "raise_issue_if_neq",
    "raise_issue_if_lt",
    "raise_issue_if_gt",
    "raise_issue_if_contains",
    "raise_issue_if_ncontains",
]

TERMINATING_PVC_LINE_REGEX = re.compile(
    r"(?P<pvc_name_from_line>.+?) is in Terminating state \(Deletion started at: (?P<deletion_timestamp>[^)]+)\)\. Finalizers: \[(?P<finalizer_parsed_from_line>[^\]]+)\]"
)

DANGLING_PV_LINE_REGEX = re.compile(
    r"Last Timestamp: (?P<last_timestamp>[^\s]+) Name: (?P<pv_name>[^\s]+) Message: (?P<pv_message>.+)"
)


def _extract_timestamp_from_log_line(log_line: str) -> str:
    """Extract timestamp from a log line, falling back to current time if none found."""
    if not log_line or not log_line.strip():
        return datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
    
    try:
        from RW.LogAnalysis.java.timestamp_handler import TimestampHandler
        handler = TimestampHandler()
        timestamp_str, _, _ = handler.extract_timestamp_from_line(log_line)
        if timestamp_str:
            dt = handler.parse_timestamp_to_datetime(timestamp_str)
            if dt:
                return dt.isoformat().replace('+00:00', 'Z')
    except Exception as e:
        logger.debug(f"Failed to extract timestamp from log line: {e}")
    
    # Fallback to current timestamp
    return datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')


def parse_cli_output_by_line(
    rsp: platform.ShellServiceResponse,
    lines_like_regexp: str = "",
    issue_if_no_capture_groups: bool = False,
    set_severity_level: int = 4,
    set_issue_expected: str = "",
    set_issue_actual: str = "",
    set_issue_reproduce_hint: str = "",
    set_issue_title: str = "",
    set_issue_details: str = "",
    set_issue_next_steps: str = "",
    set_issue_summary: str = "",
    set_issue_observations: List[Dict[str, str]] = [],
    expected_rsp_statuscodes: list[int] = [200],
    expected_rsp_returncodes: list[int] = [0],
    contains_stderr_ok: bool = True,
    raise_issue_if_no_groups_found: bool = True,
    raise_issue_from_rsp_code: bool = False,
    **kwargs,
) -> platform.ShellServiceResponse:
    """A parser that executes platform API requests as it traverses the provided stdout by line.
    This allows authors to 'raise an issue' for a given line in stdout, providing valuable information for troubleshooting.

    For each line traversed, the parser will check the contents using a variety of functions based on the kwargs provided
    with the following structure:

        <capture_group_name>__raise_issue_<query_type>=<value>

    the following capture groups are always set:
    - _stdout: the entire stdout contents
    - _line: the current line being parsed

    example: _line__raise_issue_if_contains=Error
    This will raise an issue to the platform if any _line contains the string "Error"

    - parsing needs to be performed on a platform.ShellServiceResponse object (contains the stdout)

    To set the payload of the issue that will be submitted to the platform, you can use the various
    set_issue_* arguments.

    Args:
        rsp (platform.ShellServiceResponse): The structured response from a previous command
        lines_like_regexp (str, optional): the regexp to use to create capture groups. Defaults to "".
        issue_if_no_capture_groups (bool, optional): raise an issue if no contents could be parsed to groups. Defaults to False.
        set_severity_level (int, optional): The severity of the issue, with 1 being the most critical. Defaults to 4.
        set_issue_expected (str, optional): A explanation for what we expected to see for a healthy state. Defaults to "".
        set_issue_actual (str, optional): What we actually found that's unhealthy. Defaults to "".
        set_issue_reproduce_hint (str, optional): Steps to reproduce the problem if applicable. Defaults to "".
        set_issue_title (str, optional): The title of the issue. Defaults to "".
        set_issue_details (str, optional): Further details or explanations for the issue. Defaults to "".
        set_issue_next_steps (str, optional): A next_steps query for the platform to infer suggestions from. Defaults to "".
        set_issue_summary (str, optional): A summary of the issue. Defaults to "".
        set_issue_observations (List[Dict[str, str]], optional): A list of observations for the issue. Defaults to [].
        expected_rsp_statuscodes (list[int], optional): Acceptable http codes in the response object. Defaults to [200].
        expected_rsp_returncodes (list[int], optional): Acceptable shell return codes in the response object. Defaults to [0].
        contains_stderr_ok (bool, optional): If it's acceptable for the response object to contain stderr contents. Defaults to True.
        raise_issue_if_no_groups_found (bool, optional):  Defaults to True.
        raise_issue_from_rsp_code (bool, optional): Switch to raise issue or actual exception depending on response object codes. Defaults to False.

    Returns:
        platform.ShellServiceResponse: The response object used. Typically unchanged but the stdout can be
        overrided by using the kwarg: assign_stdout_from_var=<group>
    """
    _core: Core = Core()
    issue_count: int = 0
    capture_groups: dict = {}
    stdout: str = rsp.stdout
    capture_groups["_stdout"] = stdout
    logger.info(f"stdout: {rsp.stdout}")
    logger.info(lines_like_regexp)
    logger.info(f"kwargs: {kwargs}")
    squelch_further_warnings: bool = False
    first_issue: dict = {}
    # check we've got an expected rsp
    try:
        cli_utils.verify_rsp(rsp, expected_rsp_statuscodes, expected_rsp_returncodes, contains_stderr_ok)
    except Exception as e:
        if raise_issue_from_rsp_code:
            rsp_code_title = set_issue_title if set_issue_title else "Error/Unexpected Response Code"
            rsp_code_expected = (
                set_issue_expected
                if set_issue_expected
                else f"The internal response of {rsp.cmd} should be within {expected_rsp_statuscodes} and the process response should be within {expected_rsp_returncodes}"
            )
            rsp_code_actual = (
                set_issue_actual if set_issue_actual else f"Encountered {e} as a result of running: {rsp.cmd}"
            )
            rsp_code_reproduce_hint = (
                set_issue_reproduce_hint
                if set_issue_reproduce_hint
                else f"Run command: {rsp.cmd} and check the return code"
            )
            _core.add_issue(
                severity=set_severity_level,
                title=rsp_code_title,
                expected=rsp_code_expected,
                actual=rsp_code_actual,
                reproduce_hint=rsp_code_reproduce_hint,
                details=f"{set_issue_details} ({e})",
                next_steps=set_issue_next_steps,
                summary=set_issue_summary,
                observations=set_issue_observations,
                observed_at=datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
            )
            issue_count += 1
        else:
            raise e
    terminating_pvc_summary_template = kwargs.pop("terminating_pvc_summary_template", False)
    dangling_pv_summary_template = kwargs.pop("dangling_pv_summary_template", False)
    terminating_pvc_symbols: dict = {}
    dangling_pv_symbols: dict = {}
    # begin line processing
    for line in rsp.stdout.split("\n"):
        if not line:
            continue
        capture_groups["_line"] = line
        # Extract timestamp from current line for potential issue reporting
        line_timestamp = _extract_timestamp_from_log_line(line)
        # attempt to create capture groups and values
        regexp_results = {}
        if terminating_pvc_summary_template:
            terminating_pvc_match = TERMINATING_PVC_LINE_REGEX.match(line)
            if terminating_pvc_match:
                terminating_groups = terminating_pvc_match.groupdict()
                terminating_pvc_symbols = {
                    **terminating_groups,
                    "pvc_name": terminating_groups.get("pvc_name_from_line", ""),
                    "finalizer": terminating_groups.get("finalizer_parsed_from_line", ""),
                    "deletion_time": terminating_groups.get("deletion_timestamp", ""),
                }
        if dangling_pv_summary_template:
            dangling_pv_match = DANGLING_PV_LINE_REGEX.match(line)
            if dangling_pv_match:
                dangling_groups = dangling_pv_match.groupdict()
                dangling_pv_symbols = {
                    **dangling_groups,
                    "pv_name": dangling_groups.get("pv_name", ""),
                    "pv_last_timestamp": dangling_groups.get("last_timestamp", ""),
                    "pv_message": dangling_groups.get("pv_message", ""),
                }
        if lines_like_regexp:
            regexp_results = re.match(rf"{lines_like_regexp}", line)
            if regexp_results:
                regexp_results = regexp_results.groupdict()
            logger.info(f"regexp results: {regexp_results}")
            if issue_if_no_capture_groups and (not regexp_results or len(regexp_results.keys()) == 0):
                _core.add_issue(
                    severity=set_severity_level,
                    title="No Capture Groups Found With Supplied Regex",
                    expected=f"Expected to create capture groups from line: {line} using regexp: {lines_like_regexp}",
                    actual=f"Actual result: {regexp_results}",
                    reproduce_hints=f"Try apply the regex: {lines_like_regexp} to lines produced by the command: {rsp.parsed_cmd}",
                    details=f"{set_issue_details}",
                    next_steps=f"{set_issue_next_steps}",
                    summary=set_issue_summary,
                    observations=set_issue_observations,
                    observed_at=line_timestamp,
                )
                issue_count += 1
                continue
        parse_queries = kwargs
        # if valid  regexp results and we got 1 or more capture groups, append
        if regexp_results and isinstance(regexp_results, dict) and len(regexp_results.keys()) > 0:
            capture_groups = {**regexp_results, **capture_groups}
        # begin processing kwarg queries
        for parse_query, query_value in parse_queries.items():
            severity: int = 4
            title: str = ""
            expected: str = ""
            actual: str = ""
            reproduce_hint: str = ""
            details: str = ""
            next_steps: str = ""
            query_parts = parse_query.split("__")
            if len(query_parts) != 2:
                if not squelch_further_warnings:
                    logger.warning(f"Could not parse query: {parse_query}")
                squelch_further_warnings = True
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
                # process applicable query
                if query == "raise_issue_if_eq" and query_value == capture_group_value:
                    severity = set_severity_level
                    title = (
                        f"Value Of {prefix} ({capture_group_value}) Was {query_value}"
                        if not set_issue_title
                        else set_issue_title,
                    )
                    expected = (
                        f"The parsed output {line} with regex: {lines_like_regexp} with the capture group: {prefix} should not be equal to {capture_group_value}"
                        if not set_issue_expected
                        else set_issue_expected,
                    )
                    actual = (
                        f"The parsed output {line} with regex: {lines_like_regexp} contains {prefix}=={capture_group_value} and should not be equal to {capture_group_value}"
                        if not set_issue_actual
                        else set_issue_actual
                    )
                    reproduce_hint = (
                        f"Run {rsp.cmd} and apply the regex {lines_like_regexp} per line"
                        if not set_issue_reproduce_hint
                        else set_issue_reproduce_hint
                    )
                    details = f"{set_issue_details}"
                    next_steps = f"{set_issue_next_steps}"
                    issue_count += 1
                elif query == "raise_issue_if_neq" and query_value != capture_group_value:
                    severity = set_severity_level
                    title = (
                        f"Value Of {prefix} ({capture_group_value}) Was Not {query_value}"
                        if not set_issue_title
                        else set_issue_title
                    )
                    expected = (
                        f"The parsed output {line} with regex: {lines_like_regexp} with the capture group: {prefix} should be equal to {capture_group_value}"
                        if not set_issue_expected
                        else set_issue_expected
                    )
                    actual = (
                        f"The parsed output {line} with regex: {lines_like_regexp} does not contain the expected value of: {prefix}=={capture_group_value}"
                        if not set_issue_actual
                        else set_issue_actual
                    )
                    reproduce_hint = (
                        f"Run {rsp.cmd} and apply the regex {lines_like_regexp} per line"
                        if not set_issue_reproduce_hint
                        else set_issue_reproduce_hint
                    )
                    details = f"{set_issue_details}"
                    next_steps = f"{set_issue_next_steps}"
                    issue_count += 1
                elif query == "raise_issue_if_lt" and numeric_castable and capture_group_value < query_value:
                    severity = set_severity_level
                    title = (
                        f"Value of {prefix} ({capture_group_value}) Was Less Than {query_value}"
                        if not set_issue_title
                        else set_issue_title
                    )
                    expected = (
                        f"The parsed output {line} with regex: {lines_like_regexp} should have a value >= {query_value}"
                        if not set_issue_expected
                        else set_issue_expected
                    )
                    actual = (
                        f"The parsed output {line} with regex: {lines_like_regexp} found value: {capture_group_value} and it's less than {query_value}"
                        if not set_issue_actual
                        else set_issue_actual
                    )
                    reproduce_hint = (
                        f"Run {rsp.cmd} and apply the regex {lines_like_regexp} per line"
                        if not set_issue_reproduce_hint
                        else set_issue_reproduce_hint
                    )
                    details = f"{set_issue_details}"
                    next_steps = f"{set_issue_next_steps}"
                    issue_count += 1
                elif query == "raise_issue_if_gt" and numeric_castable and capture_group_value > query_value:
                    severity = set_severity_level
                    title = (
                        f"Value of {prefix} ({capture_group_value}) Was Greater Than {query_value}"
                        if not set_issue_title
                        else set_issue_title
                    )
                    expected = (
                        f"The parsed output {line} with regex: {lines_like_regexp} should have a value <= {query_value}"
                        if not set_issue_expected
                        else set_issue_expected
                    )
                    actual = (
                        f"The parsed output {line} with regex: {lines_like_regexp} found value: {capture_group_value} and it's greater than {query_value}"
                        if not set_issue_actual
                        else set_issue_actual
                    )
                    reproduce_hint = (
                        f"Run {rsp.cmd} and apply the regex {lines_like_regexp} per line"
                        if not set_issue_reproduce_hint
                        else set_issue_reproduce_hint
                    )
                    details = f"{set_issue_details}"
                    next_steps = f"{set_issue_next_steps}"
                    issue_count += 1
                elif query == "raise_issue_if_contains" and query_value in capture_group_value:
                    severity = set_severity_level
                    title = (
                        f"Value of {prefix} ({capture_group_value}) Contained {query_value}"
                        if not set_issue_title
                        else set_issue_title
                    )
                    expected = (
                        f"The parsed output {line} with regex: {lines_like_regexp} resulted in {capture_group_value} and should not contain {query_value}"
                        if not set_issue_expected
                        else set_issue_expected
                    )
                    actual = (
                        f"The parsed output {line} with regex: {lines_like_regexp} resulted in {capture_group_value} and it contains {query_value} when it should not"
                        if not set_issue_actual
                        else set_issue_actual
                    )
                    reproduce_hint = (
                        f"Run {rsp.cmd} and apply the regex {lines_like_regexp} per line"
                        if not set_issue_reproduce_hint
                        else set_issue_reproduce_hint
                    )
                    details = f"{set_issue_details}"
                    next_steps = f"{set_issue_next_steps}"
                    issue_count += 1
                elif query == "raise_issue_if_ncontains" and query_value not in capture_group_value:
                    severity = set_severity_level
                    title = (
                        f"Value of {prefix} ({capture_group_value}) Did Not Contain {query_value}"
                        if not set_issue_title
                        else set_issue_title
                    )
                    expected = (
                        f"The parsed output {line} with regex: {lines_like_regexp} resulted in {capture_group_value} and should contain {query_value}"
                        if not set_issue_expected
                        else set_issue_expected
                    )
                    actual = (
                        f"The parsed output {line} with regex: {lines_like_regexp} resulted in {capture_group_value} and we expected to find {query_value} in the result"
                        if not set_issue_actual
                        else set_issue_actual
                    )
                    reproduce_hint = (
                        f"Run {rsp.cmd} and apply the regex {lines_like_regexp} per line"
                        if not set_issue_reproduce_hint
                        else set_issue_reproduce_hint
                    )
                    details = f"{set_issue_details}"
                    next_steps = f"{set_issue_next_steps}"
                    issue_count += 1
                if title and len(first_issue.keys()) == 0:
                    known_symbols = {**kwargs, **capture_groups, **terminating_pvc_symbols, **dangling_pv_symbols}
                    summary = (
                        Template(set_issue_summary).safe_substitute(known_symbols)
                        if set_issue_summary
                        else set_issue_summary
                    )
                    observations = set_issue_observations
                    if isinstance(observations, list):
                        templated_observations = []
                        for observation in observations:
                            if not isinstance(observation, dict):
                                templated_observations.append(observation)
                                continue
                            templated_observation = {}
                            for key, value in observation.items():
                                if isinstance(value, str):
                                    templated_observation[key] = Template(value).safe_substitute(known_symbols)
                                else:
                                    templated_observation[key] = value
                            templated_observations.append(templated_observation)
                        observations = templated_observations
                    first_issue = {
                        "title": Template(title).safe_substitute(known_symbols),
                        "severity": severity,
                        "expected": Template(expected).safe_substitute(known_symbols),
                        "actual": Template(actual).safe_substitute(known_symbols),
                        "reproduce_hint": Template(reproduce_hint).safe_substitute(known_symbols),
                        "details": Template(details).safe_substitute(known_symbols),
                        "next_steps": Template(next_steps).safe_substitute(known_symbols),
                        "observed_at": line_timestamp,
                    }
                    if summary:
                        first_issue["summary"] = summary
                    if observations:
                        first_issue["observations"] = observations
            else:
                logger.info(f"Prefix {prefix} not found in capture groups: {capture_groups.keys()}")
                continue
    if first_issue:
        # truncate long strings
        for key, value in first_issue.items():
            if isinstance(value, str) and len(value) > MAX_ISSUE_STRING_LENGTH:
                first_issue[key] = value[:MAX_ISSUE_STRING_LENGTH] + "..."
        # aggregate count into title
        if issue_count > 1:
            first_issue["title"] += f" and {issue_count-1} more"
        _core.add_issue(**first_issue)
    return rsp
