<a id="libraries.RW.CLI.cli_utils"></a>

# libraries.RW.CLI.cli\_utils

<a id="libraries.RW.CLI.cli_utils.verify_rsp"></a>

#### verify\_rsp

```python
def verify_rsp(rsp: platform.ShellServiceResponse,
               expected_rsp_statuscodes: list[int] = [200],
               expected_rsp_returncodes: list[int] = [0],
               contains_stderr_ok: bool = True) -> None
```

Utility method to verify the ShellServieResponse is in the desired state
and raise exceptions if not.

**Arguments**:

- `rsp` _platform.ShellServiceResponse_ - the rsp to verify
- `expected_rsp_statuscodes` _list[int], optional_ - the http response code returned by the process/shell service API, not the same as the bash return code. Defaults to [200].
- `expected_rsp_returncodes` _list[int], optional_ - the shell return code. Defaults to [0].
- `contains_stderr_ok` _bool, optional_ - if the presence of stderr is considered to be OK. This is expect for many CLI tools. Defaults to True.
  

**Raises**:

- `ValueError` - indicates the presence of an undesired value in the response object

<a id="libraries.RW.CLI.cli_utils.from_json"></a>

#### from\_json

```python
def from_json(json_str: str)
```

Wrapper keyword for json loads

**Arguments**:

- `json_str` _str_ - json string blob
  

**Returns**:

- `any` - the loaded json object

<a id="libraries.RW.CLI.cli_utils.to_json"></a>

#### to\_json

```python
def to_json(json_data: any)
```

Wrapper keyword for json dumps

**Arguments**:

- `json_data` _any_ - json data
  

**Returns**:

- `str` - the str representation of the json blob

<a id="libraries.RW.CLI.cli_utils.filter_by_time"></a>

#### filter\_by\_time

```python
def filter_by_time(list_data: list,
                   field_name: str,
                   operand: str = "filter_older_than",
                   duration_str: str = "30m")
```

Utility keyword to iterate through a list of dictionaries and remove list entries where
the specified key datetime is older than the given duration string.

**Arguments**:

- `list_data` _list_ - list of dictionaries to filter
- `field_name` _str_ - what key to use for comparisons
- `operand` _str, optional_ - Defaults to "filter_older_than".
- `duration_str` _str, optional_ - Duration string in the form of 3d2h1s. Defaults to "30m".
  

**Returns**:

- `_type_` - _description_

<a id="libraries.RW.CLI.cli_utils.escape_str_for_exec"></a>

#### escape\_str\_for\_exec

```python
def escape_str_for_exec(string: str, escapes: int = 1) -> str
```

Simple helper method to escape specific characters that cause issues in the pod exec passthrough

**Arguments**:

- `string` _str_ - original string for exec passthrough

**Returns**:

- `str` - string with triple escaped quotes for passthrough

<a id="libraries.RW.CLI.cli_utils.IssueCheckResults"></a>

## IssueCheckResults Objects

```python
@dataclass
class IssueCheckResults()
```

Used to keep function signatures from getting too busy when passing issue data around.

