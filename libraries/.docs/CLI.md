<a id="libraries.RW.CLI.CLI"></a>

# libraries.RW.CLI.CLI

CLI Generic keyword library for running and parsing CLI stdout

Scope: Global

<a id="libraries.RW.CLI.CLI.pop_shell_history"></a>

#### pop\_shell\_history

```python
def pop_shell_history() -> str
```

Deletes the shell history up to this point and returns it as a string for display.

**Returns**:

- `str` - the string of shell command history

<a id="libraries.RW.CLI.CLI.execute_command"></a>

#### execute\_command

```python
def execute_command(
        cmd: str,
        service: platform.Service = None,
        request_secrets: list[platform.ShellServiceRequestSecret] = None,
        env: dict = None,
        files: dict = None,
        timeout_seconds: int = 60) -> platform.ShellServiceResponse
```

Handle split between shellservice command and local process discretely.
If the user provides a service, use the traditional shellservice flow.
Otherwise we fake a ShellRequest and process it locally with a local subprocess.
Somewhat hacky as we're faking ShellResponses. Revisit this.

**Arguments**:

- `cmd` _str_ - the shell command to run
- `service` _Service, optional_ - the remote shellservice API to send the command to, if left empty defaults to run locally. Defaults to None.
- `request_secrets` _List[ShellServiceRequestSecret], optional_ - a list of secret objects to include in the request. Defaults to None.
- `env` _dict, optional_ - environment variables to set during the running of the command. Defaults to None.
- `files` _dict, optional_ - a list of files to include in the environment during the command. Defaults to None.
  

**Returns**:

- `ShellServiceResponse` - _description_

<a id="libraries.RW.CLI.CLI.run_bash_file"></a>

#### run\_bash\_file

```python
def run_bash_file(bash_file: str,
                  target_service: platform.Service = None,
                  env: dict = None,
                  include_in_history: bool = True,
                  cmd_overide: str = "",
                  timeout_seconds: int = 60,
                  **kwargs) -> platform.ShellServiceResponse
```

Runs a bash file from the local file system or remotely on a shellservice.

**Arguments**:

- `bash_file` _str_ - the name of the bashfile to run
- `target_service` _platform.Service, optional_ - the shellservice to use if provided. Defaults to None.
- `env` _dict, optional_ - a mapping of environment variables to set for the environment. Defaults to None.
- `include_in_history` _bool, optional_ - whether to include in the shell history or not. Defaults to True.
- `cmd_overide` _str, optional_ - the entrypoint command to use, similar to a dockerfile. Defaults to "./<bash_file" internally.
  

**Returns**:

- `platform.ShellServiceResponse` - the structured response from running the file.

<a id="libraries.RW.CLI.CLI.run_cli"></a>

#### run\_cli

```python
def run_cli(cmd: str,
            target_service: platform.Service = None,
            env: dict = None,
            loop_with_items: list = None,
            run_in_workload_with_name: str = "",
            run_in_workload_with_labels: str = "",
            optional_namespace: str = "",
            optional_context: str = "",
            include_in_history: bool = True,
            timeout_seconds: int = 60,
            **kwargs) -> platform.ShellServiceResponse
```

Executes a string of shell commands either locally or remotely on a shellservice.

For passing through secrets securely this can be done by using kwargs with a specific naming convention:
- for files: secret_file__kubeconfig
- for secret strings: secret__mytoken

and then to use these within your shell command use the following syntax: $${<secret_name>.key} which will cause the shell command to access where
the secret is stored in the environment it's running in.

**Arguments**:

- `cmd` _str_ - the string of shell commands to run, eg: ls -la | grep myfile
- `target_service` _platform.Service, optional_ - the remote shellservice to run the commands on if provided, otherwise run locally if None. Defaults to None.
- `env` _dict, optional_ - a mapping of environment variables to set in the environment where the shell commands are run. Defaults to None.
- `loop_with_items` _list, optional_ - deprecated. Defaults to None.
- `run_in_workload_with_name` _str, optional_ - deprecated. Defaults to "".
- `run_in_workload_with_labels` _str, optional_ - deprecated. Defaults to "".
- `optional_namespace` _str, optional_ - deprecated. Defaults to "".
- `optional_context` _str, optional_ - deprecated. Defaults to "".
- `include_in_history` _bool, optional_ - whether or not to include the shell commands in the total history. Defaults to True.
  

**Returns**:

- `platform.ShellServiceResponse` - the structured response from running the shell commands.

<a id="libraries.RW.CLI.CLI.string_to_datetime"></a>

#### string\_to\_datetime

```python
def string_to_datetime(duration_str: str) -> datetime
```

Helper to convert readable duration strings (eg: 1d2m36s) to a datetime.

