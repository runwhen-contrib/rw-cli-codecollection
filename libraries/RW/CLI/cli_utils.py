import logging, json, re
from dataclasses import dataclass
from datetime import datetime, timezone
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


def _extract_timestamp_from_log_line(log_line: str) -> str:
    """Extract timestamp from a log line, falling back to current time if none found.
    
    Supports multiple common timestamp formats including:
    - ISO 8601: 2025-11-06T14:09:22.8394565Z or 2025-11-06T14:09:22+00:00
    - RFC 3339: 2025-11-06T14:09:22.839Z
    - Common log formats: 2025-11-06 14:09:22, Nov 6 14:09:22, etc.
    
    Args:
        log_line: The log line to extract timestamp from
        
    Returns:
        ISO 8601 formatted timestamp string with 'Z' suffix (UTC)
    """
    if not log_line or not log_line.strip():
        return datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')

    observed_match = re.search(r"Observed At:\s*([0-9T:\.\-+Z]*)", log_line)
    if observed_match:
        observed_value = observed_match.group(1).strip()
        if not observed_value:
            logger.debug(f"Observed At marker found but no timestamp value in line '{log_line}'")
            return datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
        normalized = observed_value.replace("Z", "+00:00") if observed_value.endswith("Z") else observed_value
        try:
            dt = datetime.fromisoformat(normalized)
            if dt.tzinfo:
                dt = dt.astimezone(timezone.utc)
            else:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.isoformat().replace('+00:00', 'Z')
        except Exception as exc:
            logger.debug(f"Failed to parse Observed At timestamp '{observed_value}' from line '{log_line}': {exc}")

    # Common timestamp patterns ordered by specificity (most specific first)
    timestamp_patterns = [
        # ISO 8601 with high-precision fractional seconds and Z: 2025-11-06T14:09:22.8394565Z (Azure format)
        # Python's strptime only supports 6 digits, so we need special handling
        (r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7,}Z)', 'iso_high_precision'),
        
        # ISO 8601 with microseconds and Z: 2025-11-06T14:09:22.839456Z
        (r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{1,6}Z)', '%Y-%m-%dT%H:%M:%S.%fZ'),
        
        # ISO 8601 with timezone offset: 2025-11-06T14:09:22+00:00 or 2025-11-06T14:09:22-05:00
        (r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2})', '%Y-%m-%dT%H:%M:%S%z'),
        
        # ISO 8601 basic: 2025-11-06T14:09:22Z
        (r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)', '%Y-%m-%dT%H:%M:%SZ'),
        
        # ISO 8601 without timezone: 2025-11-06T14:09:22
        (r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})', '%Y-%m-%dT%H:%M:%S'),
        
        # Date with time and microseconds: 2025-11-06 14:09:22.839456
        (r'(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+)', '%Y-%m-%d %H:%M:%S.%f'),
        
        # Date with time: 2025-11-06 14:09:22
        (r'(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})', '%Y-%m-%d %H:%M:%S'),
        
        # Syslog format: Nov  6 14:09:22
        (r'([A-Z][a-z]{2}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})', '%b %d %H:%M:%S'),
        
        # Common log format with year: 06/Nov/2025:14:09:22
        (r'(\d{2}/[A-Z][a-z]{2}/\d{4}:\d{2}:\d{2}:\d{2})', '%d/%b/%Y:%H:%M:%S'),
    ]
    
    for pattern, fmt in timestamp_patterns:
        match = re.search(pattern, log_line)
        if match:
            timestamp_str = match.group(1)
            # Skip if this timestamp is part of a creationTimestamp field
            match_start = match.start()
            # Check the text before the match (up to 50 chars) for "creationTimestamp" (case-insensitive)
            text_before = log_line[max(0, match_start - 50):match_start]
            if 'creationtimestamp' in text_before.lower() or "createdat" in text_before.lower():
                logger.debug(f"Skipping timestamp '{timestamp_str}' as it's part of a creationTimestamp field")
                continue
            try:
                if fmt == 'iso_high_precision':
                    # Handle high-precision timestamps (>6 fractional digits) by truncating to 6 digits
                    # Example: 2025-11-06T14:09:22.8394565Z -> 2025-11-06T14:09:22.839456Z
                    parts = timestamp_str.rstrip('Z').split('.')
                    if len(parts) == 2:
                        date_time_part = parts[0]
                        fractional_part = parts[1][:6]  # Truncate to 6 digits (microseconds)
                        normalized_timestamp = f"{date_time_part}.{fractional_part}Z"
                        dt = datetime.strptime(normalized_timestamp, '%Y-%m-%dT%H:%M:%S.%fZ')
                        dt_utc = dt.replace(tzinfo=timezone.utc)
                        return dt_utc.isoformat().replace('+00:00', 'Z')
                elif fmt == 'unix':
                    # Unix timestamp (seconds since epoch)
                    dt = datetime.fromtimestamp(int(timestamp_str), tz=timezone.utc)
                    return dt.isoformat().replace('+00:00', 'Z')
                elif fmt == 'unix_ms':
                    # Unix timestamp in milliseconds
                    dt = datetime.fromtimestamp(int(timestamp_str) / 1000, tz=timezone.utc)
                    return dt.isoformat().replace('+00:00', 'Z')
                elif '%z' in fmt:
                    # Has timezone info
                    dt = datetime.strptime(timestamp_str, fmt)
                    # Convert to UTC
                    dt_utc = dt.astimezone(timezone.utc)
                    return dt_utc.isoformat().replace('+00:00', 'Z')
                elif fmt == '%b %d %H:%M:%S':
                    # Syslog format - assume current year and UTC
                    current_year = datetime.now(timezone.utc).year
                    timestamp_with_year = f"{timestamp_str} {current_year}"
                    dt = datetime.strptime(timestamp_with_year, '%b %d %H:%M:%S %Y')
                    # Assume UTC if no timezone specified
                    dt_utc = dt.replace(tzinfo=timezone.utc)
                    return dt_utc.isoformat().replace('+00:00', 'Z')
                else:
                    # Parse without timezone, assume UTC
                    dt = datetime.strptime(timestamp_str, fmt)
                    dt_utc = dt.replace(tzinfo=timezone.utc)
                    return dt_utc.isoformat().replace('+00:00', 'Z')
            except (ValueError, OSError) as e:
                logger.debug(f"Failed to parse timestamp '{timestamp_str}' with format '{fmt}': {e}")
                continue
    
    # No timestamp found, return current time
    logger.debug(f"No timestamp found in log line: {log_line[:100]}")
    return datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')


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
