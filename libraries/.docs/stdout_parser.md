<a id="libraries.RW.CLI.stdout_parser"></a>

# libraries.RW.CLI.stdout\_parser

CLI Generic keyword library for running and parsing CLI stdout

Scope: Global

<a id="libraries.RW.CLI.stdout_parser.parse_cli_output_by_line"></a>

#### parse\_cli\_output\_by\_line

```python
def parse_cli_output_by_line(rsp: platform.ShellServiceResponse,
                             lines_like_regexp: str = "",
                             issue_if_no_capture_groups: bool = False,
                             set_severity_level: int = 4,
                             set_issue_expected: str = "",
                             set_issue_actual: str = "",
                             set_issue_reproduce_hint: str = "",
                             set_issue_title: str = "",
                             set_issue_details: str = "",
                             set_issue_next_steps: str = "",
                             expected_rsp_statuscodes: list[int] = [200],
                             expected_rsp_returncodes: list[int] = [0],
                             contains_stderr_ok: bool = True,
                             raise_issue_if_no_groups_found: bool = True,
                             raise_issue_from_rsp_code: bool = False,
                             **kwargs) -> platform.ShellServiceResponse
```

A parser that executes platform API requests as it traverses the provided stdout by line.
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

**Arguments**:

- `rsp` _platform.ShellServiceResponse_ - The structured response from a previous command
- `lines_like_regexp` _str, optional_ - the regexp to use to create capture groups. Defaults to "".
- `issue_if_no_capture_groups` _bool, optional_ - raise an issue if no contents could be parsed to groups. Defaults to False.
- `set_severity_level` _int, optional_ - The severity of the issue, with 1 being the most critical. Defaults to 4.
- `set_issue_expected` _str, optional_ - A explanation for what we expected to see for a healthy state. Defaults to "".
- `set_issue_actual` _str, optional_ - What we actually found that's unhealthy. Defaults to "".
- `set_issue_reproduce_hint` _str, optional_ - Steps to reproduce the problem if applicable. Defaults to "".
- `set_issue_title` _str, optional_ - The title of the issue. Defaults to "".
- `set_issue_details` _str, optional_ - Further details or explanations for the issue. Defaults to "".
- `set_issue_next_steps` _str, optional_ - A next_steps query for the platform to infer suggestions from. Defaults to "".
- `expected_rsp_statuscodes` _list[int], optional_ - Acceptable http codes in the response object. Defaults to [200].
- `expected_rsp_returncodes` _list[int], optional_ - Acceptable shell return codes in the response object. Defaults to [0].
- `contains_stderr_ok` _bool, optional_ - If it's acceptable for the response object to contain stderr contents. Defaults to True.
- `raise_issue_if_no_groups_found` _bool, optional_ - Defaults to True.
- `raise_issue_from_rsp_code` _bool, optional_ - Switch to raise issue or actual exception depending on response object codes. Defaults to False.
  

**Returns**:

- `platform.ShellServiceResponse` - The response object used. Typically unchanged but the stdout can be
  overrided by using the kwarg: assign_stdout_from_var=<group>

