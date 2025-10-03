import logging, json, jmespath
from string import Template
from RW import platform
from RW.Core import Core

from . import cli_utils

logger = logging.getLogger(__name__)
ROBOT_LIBRARY_SCOPE = "GLOBAL"

MAX_ISSUE_STRING_LENGTH: int = 1920

RECOGNIZED_JSON_PARSE_QUERIES = [
    "raise_issue_if_eq",
    "raise_issue_if_neq",
    "raise_issue_if_lt",
    "raise_issue_if_gt",
    "raise_issue_if_contains",
    "raise_issue_if_ncontains",
]
EXTRACT_PREFIX = "extract_path_to_var"
ASSIGN_PREFIX = "from_var_with_path"
ASSIGN_STDOUT_PREFIX = "assign_stdout_from_var"
ASSIGN_STDOUT_PREFIX = "assign_stdout_from_var"

RECOGNIZED_FILTERS = [
    "filter_older_than",
    "filter_newer_than",
]


def parse_cli_json_output(
    rsp: platform.ShellServiceResponse,
    set_severity_level: int = 4,
    set_issue_expected: str = "",
    set_issue_actual: str = "",
    set_issue_reproduce_hint: str = "",
    set_issue_title: str = "",
    set_issue_details: str = "",
    set_issue_next_steps: str = "",
    expected_rsp_statuscodes: list[int] = [200],
    expected_rsp_returncodes: list[int] = [0],
    raise_issue_from_rsp_code: bool = False,
    contains_stderr_ok: bool = True,
    **kwargs,
) -> platform.ShellServiceResponse:
    """Parser for json blob data that can raise issues to the RunWhen platform based on data found.
    Queries can be performed on the data using various kwarg structures with the following syntax:

    kwarg syntax:
    - extract_path_to_var__{variable_name}
    - from_var_with_path__{variable1}__to__{variable2}
    - assign_stdout_from_var
    - {variable_name}__raise_issue_if_gt|lt|contains|ncontains|eq|neq

    Using the `__` delimiters to separate values and prefixes.


    Args:
        rsp (platform.ShellServiceResponse): _description_
        set_severity_level (int, optional): the severity of the issue if it's raised. Defaults to 4.
        set_issue_expected (str, optional): what we expected in the json data. Defaults to "".
        set_issue_actual (str, optional): what was actually detected in the json data. Defaults to "".
        set_issue_reproduce_hint (str, optional): reproduce hints as a string. Defaults to "".
        set_issue_title (str, optional): the title of the issue if raised. Defaults to "".
        set_issue_details (str, optional): details on the issue if raised. Defaults to "".
        set_issue_next_steps (str, optional): next steps or tasks to run based on this issue if raised. Defaults to "".
        expected_rsp_statuscodes (list[int], optional): allowed http codes in the response being parsed. Defaults to [200].
        expected_rsp_returncodes (list[int], optional): allowed shell return codes in the response being parsed. Defaults to [0].
        raise_issue_from_rsp_code (bool, optional): if true, raise an issue when the response object fails validation. Defaults to False.
        contains_stderr_ok (bool, optional): whether or not to fail validation of the response object when it contains stderr. Defaults to True.

    Returns:
        platform.ShellServiceResponse: the unchanged response object that was parsed, for subsequent parses.
    """
    # used to store manipulated data
    variable_results = {}
    # used to keep track of how we got the data
    # TODO: transitive lookups
    variable_from_path = {}
    # for making api requests with raise issue
    _core: Core = Core()
    logger.info(f"kwargs: {kwargs}")
    found_issue: bool = False
    variable_results["_stdout"] = rsp.stdout
    # check we've got an expected rsp
    try:
        cli_utils.verify_rsp(rsp, expected_rsp_statuscodes, expected_rsp_returncodes, contains_stderr_ok)
    except Exception as e:
        if raise_issue_from_rsp_code:
            rsp_code_title = set_issue_title if set_issue_title else "Error/Unexpected Response Code"
            rsp_next_steps = set_issue_next_steps if set_issue_next_steps else "View the logs of the shellservice"
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
                next_steps=rsp_next_steps,
            )
        else:
            raise e
    json_data = json.loads(rsp.stdout)
    # create extractions first
    for key in kwargs.keys():
        kwarg_parts = key.split("__")
        prefix = kwarg_parts[0]
        if prefix != EXTRACT_PREFIX or len(kwarg_parts) != 2:
            continue
        logger.info(f"Got kwarg parts: {kwarg_parts}")
        jmespath_str = kwargs[key]
        varname = kwarg_parts[1]
        try:
            jmespath_result = jmespath.search(jmespath_str, json_data)
            if jmespath_result == None:
                logger.warning(
                    f"The jmespath extraction string: {jmespath_str} returned None for the variable: {varname} with kwarg parts: {kwarg_parts} - did a previous extract fail?"
                )
            variable_results[varname] = jmespath_result
            variable_from_path[varname] = jmespath_str
        except Exception as e:
            logger.warning(
                f"Failed to extract jmespath data: {json.dumps(variable_results[varname])} with path: {jmespath_str} due to: {e}"
            )
            variable_results[varname] = None
    # handle var to var assignments
    for key in kwargs.keys():
        kwarg_parts = key.split("__")
        prefix = kwarg_parts[0]
        if prefix != ASSIGN_PREFIX or len(kwarg_parts) != 4:
            continue
        logger.info(f"Got kwarg parts: {kwarg_parts}")
        jmespath_str = kwargs[key]
        from_varname = kwarg_parts[1]
        if from_varname not in variable_results.keys():
            logger.warning(
                f"attempted to reference from_var {from_varname} when it has not been created yet. Available vars: {variable_results.keys()}"
            )
            continue
        to_varname = kwarg_parts[3]
        try:
            if variable_results[from_varname] == None:
                raise Exception(
                    f"Referenced variable: {from_varname} is None in {variable_results} - did a previous extract fail?"
                )
            variable_results[to_varname] = jmespath.search(jmespath_str, variable_results[from_varname])
            variable_from_path[to_varname] = jmespath_str
        except Exception as e:
            logger.warning(
                f"Failed to extract jmespath data: {json.dumps(variable_results[from_varname])} with path: {jmespath_str} due to: {e}"
            )
            variable_results[to_varname] = None
            variable_from_path[to_varname] = jmespath_str
    # begin filtering
    for key in kwargs.keys():
        kwarg_parts = key.split("__")
        logger.info(f"Got kwarg parts: {kwarg_parts}")
        if len(kwarg_parts) != 3:
            continue
        varname = kwarg_parts[0]
        filter_type = kwarg_parts[1]
        if filter_type not in RECOGNIZED_FILTERS:
            logger.warning(f"filter: {filter_type} is not in the expected types: {RECOGNIZED_FILTERS}")
            continue
        filter_amount = kwarg_parts[2]
        field_to_filter_on = kwargs[key]
        variable_results[varname] = cli_utils.filter_by_time(
            variable_results[varname], field_to_filter_on, filter_type, filter_amount
        )
    # begin searching for issues
    # break at first found issue
    # TODO: revisit how we submit multiple chained issues
    # TODO: cleanup, reorg this
    issue_results = _check_for_json_issue(
        rsp,
        variable_from_path,
        variable_results,
        set_severity_level,
        set_issue_expected,
        set_issue_actual,
        set_issue_reproduce_hint,
        set_issue_title,
        set_issue_details,
        set_issue_next_steps,
        **kwargs,
    )
    if issue_results.issue_found:
        known_symbols = {**kwargs, **variable_results}
        issue_data = {
            "title": Template(issue_results.title).safe_substitute(known_symbols),
            "severity": issue_results.severity,
            "expected": Template(issue_results.expected).safe_substitute(known_symbols),
            "actual": Template(issue_results.actual).safe_substitute(known_symbols),
            "reproduce_hint": Template(issue_results.reproduce_hint).safe_substitute(known_symbols),
            "details": Template(issue_results.details).safe_substitute(known_symbols),
            "next_steps": Template(issue_results.next_steps).safe_substitute(known_symbols),
        }
        # truncate long strings
        for key, value in issue_data.items():
            if isinstance(value, str) and len(value) > MAX_ISSUE_STRING_LENGTH:
                issue_data[key] = value[:MAX_ISSUE_STRING_LENGTH] + "..."
        _core.add_issue(**issue_data)
    # override rsp stdout for parse chaining
    for key in kwargs.keys():
        kwarg_parts = key.split("__")
        logger.info(f"Got kwarg parts: {kwarg_parts}")
        prefix = kwarg_parts[0]
        if prefix != ASSIGN_STDOUT_PREFIX or len(kwarg_parts) != 1:
            continue
        from_varname = kwargs[key]
        if from_varname not in variable_results.keys():
            logger.warning(
                f"attempted to reference from_var {from_varname} when it has not been created yet. Available vars: {variable_results.keys()}"
            )
            continue
        try:
            variable_as_json = json.dumps(variable_results[from_varname])
            rsp = cli_utils._overwrite_shell_rsp_stdout(rsp, variable_as_json)
            logger.info(f"Assigned to rsp.stdout: {variable_as_json}")
        except Exception as e:
            logger.error(f"Unable to assign variable: {variable_results[from_varname]} to rsp.stdout due to {e}")
    return rsp


def _check_for_json_issue(
    rsp: platform.ShellServiceResponse,
    variable_from_path: dict,
    variable_results: dict,
    set_severity_level: int = 4,
    set_issue_expected: str = "",
    set_issue_actual: str = "",
    set_issue_reproduce_hint: str = "",
    set_issue_title: str = "",
    set_issue_details: str = "",
    set_issue_next_steps: str = "",
    **kwargs,
) -> cli_utils.IssueCheckResults:
    """Internal method to perform checks for issues in json data.
    See `parse_cli_json_output`
    """
    severity: int = 4
    title: str = ""
    expected: str = ""
    actual: str = ""
    details: str = ""
    next_steps: str = ""
    reproduce_hint: str = ""
    issue_found: bool = False
    parse_queries = kwargs
    query: str = ""
    issue_results: cli_utils.IssueCheckResults = None
    for parse_query, query_value in parse_queries.items():
        # figure out what issue we're querying for in the data
        query_parts = parse_query.split("__")
        prefix = query_parts[0]
        if prefix == EXTRACT_PREFIX or prefix == ASSIGN_PREFIX or prefix == ASSIGN_STDOUT_PREFIX:
            # skip, we've already processed these
            continue
        if len(query_parts) != 2:
            continue
        if query in RECOGNIZED_FILTERS:
            # we've already processed filters
            continue
        query = query_parts[1]
        logger.info(f"Got prefix: {prefix} and query: {query}")
        if query not in RECOGNIZED_JSON_PARSE_QUERIES:
            logger.info(f"Query {query} not in recognized list: {RECOGNIZED_JSON_PARSE_QUERIES}")
            continue
        if prefix not in variable_results.keys():
            logger.warning(
                f"Variable {prefix} hasn't been defined by assignment or extract, try define it in {variable_results.keys()} first"
            )
            continue
        numeric_castable: bool = False
        variable_value = variable_results[prefix]
        variable_is_list: bool = isinstance(variable_value, list)
        # precompare cast if comparing numbers
        if query in ["raise_issue_if_gt", "raise_issue_if_lt"]:
            try:
                query_value = float(query_value)
                variable_value = float(variable_value)
                numeric_castable = True
            except Exception as e:
                logger.warning(
                    f"Numeric parse query requested but values not castable: {query_value} and {variable_value}"
                )
        # If True/False string passed from robot layer, cast it to bool
        if not numeric_castable and (query_value == "True" or query_value == "False"):
            query_value = True if query_value == "True" else False
        if query == "raise_issue_if_eq" and (
            str(query_value) == str(variable_value) or (variable_is_list and query_value in variable_value)
        ):
            issue_found = True
            title = f"Value Of {prefix} Was {variable_value}"
            expected = f"The parsed output {variable_value} stored in {prefix} using the path: {variable_from_path[prefix]} should not be equal to {query_value}"
            actual = f"The parsed output {variable_value} stored in {prefix} using the path: {variable_from_path[prefix]} is equal to {variable_value}"
            reproduce_hint = f"Run {rsp.cmd} and apply the jmespath '{variable_from_path[prefix]}' to the output"
            details = f"{set_issue_details}"
            next_steps = f"{set_issue_next_steps}"
        elif query == "raise_issue_if_neq" and (
            str(query_value) != str(variable_value) or (variable_is_list and query_value not in variable_value)
        ):
            issue_found = True
            title = f"Value of {prefix} Was Not {query_value}"
            expected = f"The parsed output {variable_value} stored in {prefix} using the path: {variable_from_path[prefix]} should be equal to {variable_value}"
            actual = f"The parsed output {variable_value} stored in {prefix} using the path: {variable_from_path[prefix]} does not contain the expected value of: {prefix}=={query_value} and is actually {variable_value}"
            reproduce_hint = f"Run {rsp.cmd} and apply the jmespath '{variable_from_path[prefix]}' to the output"
            details = f"{set_issue_details}"
            next_steps = f"{set_issue_next_steps}"

        elif query == "raise_issue_if_lt" and numeric_castable and variable_value < query_value:
            issue_found = True
            title = f"Value of {prefix} Was Less Than {query_value}"
            expected = f"The parsed output {variable_value} stored in {prefix} using the path: {variable_from_path[prefix]} should have a value >= {query_value}"
            actual = f"The parsed output {variable_value} stored in {prefix} using the path: {variable_from_path[prefix]} found value: {variable_value} and it's less than {query_value}"
            reproduce_hint = f"Run {rsp.cmd} and apply the jmespath '{variable_from_path[prefix]}' to the output"
            details = f"{set_issue_details}"
            next_steps = f"{set_issue_next_steps}"

        elif query == "raise_issue_if_gt" and numeric_castable and variable_value > query_value:
            issue_found = True
            title = f"Value of {prefix} Was Greater Than {query_value}"
            expected = f"The parsed output {variable_value} stored in {prefix} using the path: {variable_from_path[prefix]} should have a value <= {query_value}"
            actual = f"The parsed output {variable_value} stored in {prefix} using the path: {variable_from_path[prefix]} found value: {variable_value} and it's greater than {query_value}"
            reproduce_hint = f"Run {rsp.cmd} and apply the jmespath '{variable_from_path[prefix]}' to the output"
            details = f"{set_issue_details}"
            next_steps = f"{set_issue_next_steps}"

        elif query == "raise_issue_if_contains" and query_value in variable_value:
            issue_found = True
            title = f"Value of {prefix} Contained {query_value}"
            expected = f"The parsed output {variable_value} stored in {prefix} using the path: {variable_from_path[prefix]} resulted in {variable_value} and should not contain {query_value}"
            actual = f"The parsed output {variable_value} stored in {prefix} using the path: {variable_from_path[prefix]} resulted in {variable_value} and it contains {query_value} when it should not"
            reproduce_hint = f"Run {rsp.cmd} and apply the jmespath '{variable_from_path[prefix]}' to the output"
            details = f"{set_issue_details}"
            next_steps = f"{set_issue_next_steps}"

        elif query == "raise_issue_if_ncontains" and query_value not in variable_value:
            issue_found = True
            title = f"Value of {prefix} Did Not Contain {query_value}"
            expected = f"The parsed output {variable_value} stored in {prefix} using the path: {variable_from_path[prefix]} resulted in {variable_value} and should contain {query_value}"
            actual = f"The parsed output {variable_value} stored in {prefix} using the path: {variable_from_path[prefix]} resulted in {variable_value} and we expected to find {query_value} in the result"
            reproduce_hint = f"Run {rsp.cmd} and apply the jmespath '{variable_from_path[prefix]}' to the output"
            details = f"{set_issue_details}"
            next_steps = f"{set_issue_next_steps}"

        # Explicit sets
        if set_severity_level:
            severity = set_severity_level
        if set_issue_title:
            title = set_issue_title
        if set_issue_expected:
            expected = set_issue_expected
        if set_issue_actual:
            actual = set_issue_actual
        if set_issue_reproduce_hint:
            reproduce_hint = set_issue_reproduce_hint
        if set_issue_next_steps:
            next_steps = set_issue_next_steps
        if issue_found:
            break
    # return struct like results
    return cli_utils.IssueCheckResults(
        query_type=query,
        severity=severity,
        title=title,
        expected=expected,
        actual=actual,
        reproduce_hint=reproduce_hint,
        issue_found=issue_found,
        details=details,
        next_steps=next_steps,
    )
