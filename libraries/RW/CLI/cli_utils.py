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
    """Helper method to create a new shell response object
    from the ShellServiceResponse dataclass which is frozen.

    Args:
        rsp (platform.ShellServiceResponse): the original response
        new_stdout (str): the new stdout to insert

    Returns:
        platform.ShellServiceResponse: a copy of the response object with the new stdout
    """
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
    """Utility method to verify the ShellServieResponse is in the desired state
    and raise exceptions if not.

    Args:
        rsp (platform.ShellServiceResponse): the rsp to verify
        expected_rsp_statuscodes (list[int], optional): the http response code returned by the process/shell service API, not the same as the bash return code. Defaults to [200].
        expected_rsp_returncodes (list[int], optional): the shell return code. Defaults to [0].
        contains_stderr_ok (bool, optional): if the presence of stderr is considered to be OK. This is expect for many CLI tools. Defaults to True.

    Raises:
        ValueError: indicates the presence of an undesired value in the response object
    """
    if not contains_stderr_ok and rsp.stderr:
        raise ValueError(f"rsp {rsp} contains unexpected stderr {rsp.stderr}")
    if rsp.status not in expected_rsp_statuscodes:
        raise ValueError(f"rsp {rsp} has unexpected HTTP status {rsp.status}")
    if rsp.returncode not in expected_rsp_returncodes:
        raise ValueError(f"rsp {rsp} has unexpected shell return code {rsp.returncode}")


def _string_to_datetime(duration_str: str, date_format_str="%Y-%m-%dT%H:%M:%SZ"):
    """Utility method to create a datetime from a duration string

    Args:
        duration_str (str): a duration string, eg: 3d2h1s used to get a past datetime
        date_format_str (str, optional): datetime format. Defaults to "%Y-%m-%dT%H:%M:%SZ".

    Returns:
        datetime: the past datetime derived from the duration_str
    """
    now = RobotDateTime.get_current_date(result_format=date_format_str)
    time = RobotDateTime.convert_time(duration_str)
    past_date = RobotDateTime.subtract_time_from_date(now, time, result_format=date_format_str)
    return past_date


def from_json(json_str: str):
    """Wrapper keyword for json loads

    Args:
        json_str (str): json string blob

    Returns:
        any: the loaded json object
    """
    return json.loads(json_str, strict=False)


def to_json(json_data: any):
    """Wrapper keyword for json dumps

    Args:
        json_data (any): json data

    Returns:
        str: the str representation of the json blob
    """
    return json.dumps(json_str)


def filter_by_time(
    list_data: list,
    field_name: str,
    operand: str = "filter_older_than",
    duration_str: str = "30m",
):
    """Utility keyword to iterate through a list of dictionaries and remove list entries where
    the specified key datetime is older than the given duration string.

    Args:
        list_data (list): list of dictionaries to filter
        field_name (str): what key to use for comparisons
        operand (str, optional): Defaults to "filter_older_than".
        duration_str (str, optional): Duration string in the form of 3d2h1s. Defaults to "30m".

    Returns:
        _type_: _description_
    """
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
