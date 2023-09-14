<a id="libraries.RW.CLI.CLI"></a>

# libraries.RW.CLI.CLI

CLI Generic keyword library for running and parsing CLI stdout

Scope: Global

<a id="libraries.RW.CLI.CLI.execute_command"></a>

#### execute\_command

```python
def execute_command(cmd: str,
                    service: platform.Service = None,
                    request_secrets: list[
                        platform.ShellServiceRequestSecret] = None,
                    env: dict = None,
                    files: dict = None) -> platform.ShellServiceResponse
```

Handle split between shellservice command and local process discretely.
If the user provides a service, use the traditional shellservice flow.
Otherwise we fake a ShellRequest and process it locally with a local subprocess.
Somewhat hacky as we're faking ShellResponses. Revisit this.

**Arguments**:

- `cmd` _str_ - _description_
- `service` _Service, optional_ - _description_. Defaults to None.
- `request_secrets` _List[ShellServiceRequestSecret], optional_ - _description_. Defaults to None.
- `env` _dict, optional_ - _description_. Defaults to None.
- `files` _dict, optional_ - _description_. Defaults to None.
  

**Returns**:

- `ShellServiceResponse` - _description_

