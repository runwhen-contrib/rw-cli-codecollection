<a id="libraries.RW.K8sApplications.k8s_applications"></a>

# libraries.RW.K8sApplications.k8s\_applications

<a id="libraries.RW.K8sApplications.k8s_applications.dynamic_parse_stacktraces"></a>

#### dynamic\_parse\_stacktraces

```python
def dynamic_parse_stacktraces(
        logs: str,
        parser_name: str = "",
        parse_mode: str = "SPLIT",
        show_debug: bool = False) -> list[StackTraceData]
```

Allows for dynamic parsing of stacktraces based on the first log line
if no parser name is provided, the first log line will be used to determine the parser to use
based on a map lookup of parser types to their respective parsers

**Arguments**:

- `logs` _str_ - the log data to parse
- `parser_name` _str, optional_ - the name of the parser to lookup for use. Defaults to "".
- `parse_mode` _ParseMode, optional_ - how to modify the ingested logs, typically we want to split them on newlines. Defaults to ParseMode.SPLIT_INPUT.
- `show_debug` _bool, optional_ - Defaults to False.
  

**Returns**:

- `list[StackTraceData]` - Returns a list of StackTraceData objects that contain the parsed stacktrace data to be leveraged by other functions

