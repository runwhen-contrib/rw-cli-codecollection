import logging, json
from dataclasses import dataclass
from datetime import datetime
import dateutil.parser

from robot.libraries.BuiltIn import BuiltIn
from robot.libraries import DateTime as RobotDateTime


from RW import platform
from RW.Core import Core

logger = logging.getLogger(__name__)


def _overwrite_shell_rsp_stdout(
    rsp: platform.ShellServiceResponse,
    new_stdout: str,
) -> platform.ShellServiceResponse:
    new_rsp: platform.ShellServiceResponse = platform.ShellServiceResponse(
        cmd=rsp.cmd,
        parsed_cmd=rsp.parsed_cmd,
        stdout=new_stdout,
        stderr=rsp.stderr,
        returncode=rsp.returncode,
        status=rsp.status,
        body=rsp.body,
        errors=rsp.errors,
    )
    return new_rsp


def verify_rsp(
    rsp: platform.ShellServiceResponse,
    expected_rsp_statuscodes: list[int] = [200],
    expected_rsp_returncodes: list[int] = [0],
    contains_stderr_ok: bool = True,
) -> None:
    if not contains_stderr_ok and rsp.stderr:
        raise ValueError(f"rsp {rsp} contains unexpected stderr {rsp.stderr}")
    if rsp.status not in expected_rsp_statuscodes:
        raise ValueError(f"rsp {rsp} has unexpected HTTP status {rsp.status}")
    if rsp.returncode not in expected_rsp_returncodes:
        raise ValueError(f"rsp {rsp} has unexpected shell return code {rsp.returncode}")


def _string_to_datetime(duration_str: str, date_format_str="%Y-%m-%dT%H:%M:%SZ"):
    now = RobotDateTime.get_current_date(result_format=date_format_str)
    time = RobotDateTime.convert_time(duration_str)
    past_date = RobotDateTime.subtract_time_from_date(now, time, result_format=date_format_str)
    return past_date


def from_json(json_str: str):
    return json.loads(json_str, strict=False)


def to_json(json_data: any):
    return json.dumps(json_str)


def filter_by_time(
    list_data: list,
    field_name: str,
    operand: str = "filter_older_than",
    duration_str: str = "30m",
):
    results: list = []
    time_to_filter = _string_to_datetime(duration_str)
    time_to_filter = dateutil.parser.parse(time_to_filter).replace(tzinfo=None)
    for row in list_data:
        if field_name not in row:
            continue
        row_time = dateutil.parser.parse(row[field_name]).replace(tzinfo=None)
        logger.info(f"types: {type(row_time)} {type(time_to_filter)}")
        logger.info(f"compare: {row_time} {time_to_filter} and >=: {row_time >= time_to_filter}")
        if operand == "filter_older_than":
            if row_time >= time_to_filter:
                results.append(row)
        elif operand == "filter_newer_than":
            if row_time <= time_to_filter:
                results.append(row)
        else:
            logger.info(f"dropped: {row}")
    return results


def escape_str_for_exec(string: str, escapes: int = 1) -> str:
    """Simple helper method to escape specific characters that cause issues in the pod exec passthrough
    Args:
        string (str): original string for exec passthrough
    Returns:
        str: string with triple escaped quotes for passthrough
    """
    string = string.replace('"', "\\" * escapes + '"')
    return string


@dataclass
class IssueCheckResults:
    """
    Used to keep function signatures from getting too busy when passing issue data around.
    """

    query_type: str = ""
    severity: int = 4
    title: str = ""
    expected: str = ""
    actual: str = ""
    reproduce_hint: str = ""
    issue_found: bool = False
    details: str = ""
    next_steps: str = ""
