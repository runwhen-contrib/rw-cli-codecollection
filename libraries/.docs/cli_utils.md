<a id="libraries.RW.CLI.cli_utils"></a>

# libraries.RW.CLI.cli\_utils

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

