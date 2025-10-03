<a id="libraries.RW.CLI.json_parser"></a>

# libraries.RW.CLI.json\_parser

<a id="libraries.RW.CLI.json_parser.parse_cli_json_output"></a>

#### parse\_cli\_json\_output

```python
def parse_cli_json_output(rsp: platform.ShellServiceResponse,
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
                          **kwargs) -> platform.ShellServiceResponse
```

Parser for json blob data that can raise issues to the RunWhen platform based on data found.
Queries can be performed on the data using various kwarg structures with the following syntax:

kwarg syntax:
- extract_path_to_var__{variable_name}
- from_var_with_path__{variable1}__to__{variable2}
- assign_stdout_from_var
- {variable_name}__raise_issue_if_gt|lt|contains|ncontains|eq|neq

Using the `__` delimiters to separate values and prefixes.


**Arguments**:

- `rsp` _platform.ShellServiceResponse_ - _description_
- `set_severity_level` _int, optional_ - the severity of the issue if it's raised. Defaults to 4.
- `set_issue_expected` _str, optional_ - what we expected in the json data. Defaults to "".
- `set_issue_actual` _str, optional_ - what was actually detected in the json data. Defaults to "".
- `set_issue_reproduce_hint` _str, optional_ - reproduce hints as a string. Defaults to "".
- `set_issue_title` _str, optional_ - the title of the issue if raised. Defaults to "".
- `set_issue_details` _str, optional_ - details on the issue if raised. Defaults to "".
- `set_issue_next_steps` _str, optional_ - next steps or tasks to run based on this issue if raised. Defaults to "".
- `expected_rsp_statuscodes` _list[int], optional_ - allowed http codes in the response being parsed. Defaults to [200].
- `expected_rsp_returncodes` _list[int], optional_ - allowed shell return codes in the response being parsed. Defaults to [0].
- `raise_issue_from_rsp_code` _bool, optional_ - if true, raise an issue when the response object fails validation. Defaults to False.
- `contains_stderr_ok` _bool, optional_ - whether or not to fail validation of the response object when it contains stderr. Defaults to True.
  

**Returns**:

- `platform.ShellServiceResponse` - the unchanged response object that was parsed, for subsequent parses.

