"""
CLI Generic keyword library for running and parsing CLI stdout

Scope: Global
"""
import re, logging, json, jmespath, os
from datetime import datetime
from robot.libraries.BuiltIn import BuiltIn
import shlex
 
from RW import platform
from RW.Core import Core

# import bare names for robot keyword names
from .json_parser import *
from .stdout_parser import *
from .cli_utils import _string_to_datetime, from_json, verify_rsp, escape_str_for_exec
from .local_process import execute_local_command

logger = logging.getLogger(__name__)

ROBOT_LIBRARY_SCOPE = "GLOBAL"

SHELL_HISTORY: list[str] = []
SECRET_PREFIX = "secret__"
SECRET_FILE_PREFIX = "secret_file__"

def escape_string(string):
    return repr(string)

def escape_bash_command(command):
    """
    Escapes a command for safe execution in bash.
    """
    return shlex.quote(command)

def pop_shell_history() -> str:
    """Deletes the shell history up to this point and returns it as a string for display.

    Returns:
        str: the string of shell command history
    """
    global SHELL_HISTORY
    history: str = "\n".join(SHELL_HISTORY)
    SHELL_HISTORY = []
    return history


def execute_command(
    cmd: str,
    service: platform.Service = None,
    request_secrets: list[platform.ShellServiceRequestSecret] = None,
    env: dict = None,
    files: dict = None,
    timeout_seconds: int = 60,
) -> platform.ShellServiceResponse:
    """Handle split between shellservice command and local process discretely.
    If the user provides a service, use the traditional shellservice flow.
    Otherwise we fake a ShellRequest and process it locally with a local subprocess.
    Somewhat hacky as we're faking ShellResponses. Revisit this.

    Args:
        cmd (str): the shell command to run
        service (Service, optional): the remote shellservice API to send the command to, if left empty defaults to run locally. Defaults to None.
        request_secrets (List[ShellServiceRequestSecret], optional): a list of secret objects to include in the request. Defaults to None.
        env (dict, optional): environment variables to set during the running of the command. Defaults to None.
        files (dict, optional): a list of files to include in the environment during the command. Defaults to None.

    Returns:
        ShellServiceResponse: _description_
    """
    if not service:
        return execute_local_command(
            cmd=cmd,
            request_secrets=request_secrets,
            env=env,
            files=files,
            timeout_seconds=timeout_seconds,
        )
    else:
        return platform.execute_shell_command(
            cmd=cmd,
            service=service,
            request_secrets=request_secrets,
            env=env,
            files=files,
        )


def _create_kubernetes_remote_exec(
    cmd: str,
    target_service: platform.Service = None,
    env: dict = None,
    labels: str = "",
    workload_name: str = "",
    namespace: str = "",
    context: str = "",
    **kwargs,
) -> str:
    """**DEPRECATED**"""
    # if no specific workload name but labels provided, fetch the first running pod with labels
    if not workload_name and labels:
        request_secrets: [platform.ShellServiceRequestSecret] = (
            [] if len(kwargs.keys()) > 0 else None
        )
        request_secrets = _create_secrets_from_kwargs(**kwargs)
        pod_name_cmd = (
            f"kubectl get pods --field-selector=status.phase==Running -l {labels}"
            + " -o jsonpath='{.items[0].metadata.name}'"
            + f" -n {namespace} --context={context}"
        )
        rsp = execute_command(
            cmd=pod_name_cmd,
            service=target_service,
            request_secrets=request_secrets,
            env=env,
        )
        SHELL_HISTORY.append(pod_name_cmd)
        cli_utils.verify_rsp(rsp)
        workload_name = rsp.stdout
    # use eval so that env variables are evaluated in the subprocess
    cmd_template: str = f"eval $(echo \"kubectl exec -n {namespace} --context={context} {workload_name} -- /bin/bash -c '{cmd}'\")"
    cmd = cmd_template
    logger.info(f"Templated remote exec: {cmd}")
    return cmd


def _create_secrets_from_kwargs(**kwargs) -> list[platform.ShellServiceRequestSecret]:
    """Helper to organize dynamically set secrets in a kwargs list

    Returns:
        list[platform.ShellServiceRequestSecret]: secrets objects in list form.
    """
    global SECRET_PREFIX
    global SECRET_FILE_PREFIX
    request_secrets: list[platform.ShellServiceRequestSecret] = (
        [] if len(kwargs.keys()) > 0 else None
    )
    for key, value in kwargs.items():
        if not key.startswith(SECRET_PREFIX) and not key.startswith(SECRET_FILE_PREFIX):
            continue
        if not isinstance(value, platform.Secret):
            logger.warning(
                f"kwarg secret {value} in key {key} is the wrong type, should be platform.Secret"
            )
            continue
        if key.startswith(SECRET_PREFIX):
            request_secrets.append(platform.ShellServiceRequestSecret(value))
        elif key.startswith(SECRET_FILE_PREFIX):
            request_secrets.append(
                platform.ShellServiceRequestSecret(value, as_file=True)
            )
    return request_secrets

def find_file(*paths):
    """ Helper function to check if a file exists in the given paths. """
    for path in paths:
        if os.path.isfile(path):
            return path
    return None

def resolve_path_to_robot():
    # Environment variables
    runwhen_home = os.getenv("RUNWHEN_HOME", "").rstrip('/')
    home = os.getenv("HOME", "").rstrip('/')

    # Get the path to the robot file, ensure it's clean for concatenation
    repo_path_to_robot = os.getenv("RW_PATH_TO_ROBOT", "").lstrip('/')

    # Check if the path includes environment variable placeholders
    if "$(RUNWHEN_HOME)" in repo_path_to_robot:
        repo_path_to_robot = repo_path_to_robot.replace("$(RUNWHEN_HOME)", runwhen_home)
    if "$(HOME)" in repo_path_to_robot:
        repo_path_to_robot = repo_path_to_robot.replace("$(HOME)", home)

    # Prepare a list of paths to check
    paths_to_check = set([
        os.path.join('/', repo_path_to_robot),  # Check as absolute path
        os.path.join(runwhen_home, repo_path_to_robot),  # Path relative to RUNWHEN_HOME
        os.path.join(runwhen_home, 'collection', repo_path_to_robot),  # Further nested within RUNWHEN_HOME
        os.path.join(home, repo_path_to_robot),  # Path relative to HOME
        os.path.join(home, 'collection', repo_path_to_robot),  # Further nested within HOME
        os.path.join("/collection", repo_path_to_robot), # Common collection path
        os.path.join("/root/", repo_path_to_robot), # Backwards compatible /root
        os.path.join("/root/collection", repo_path_to_robot), # Backwards compatible /root
    ])

    # Try to find the file in any of the specified paths
    file_path = find_file(*paths_to_check)
    if file_path:
        return file_path

    # Final fallback to a default robot file or raise an error
    default_robot_file = os.path.join("/", "sli.robot")  # Default file path
    if os.path.isfile(default_robot_file):
        return default_robot_file

    raise FileNotFoundError("Could not find the robot file in any known locations.")



def run_bash_file(
    bash_file: str,
    target_service: platform.Service = None,
    env: dict = None,
    include_in_history: bool = True,
    cmd_override: str = "",
    timeout_seconds: int = 60,
    **kwargs,
) -> platform.ShellServiceResponse:
    """Runs a bash file from the local file system or remotely on a shellservice.

    Args:
        bash_file (str): the name of the bashfile to run
        target_service (platform.Service, optional): the shellservice to use if provided. Defaults to None.
        env (dict, optional): a mapping of environment variables to set for the environment. Defaults to None.
        include_in_history (bool, optional): whether to include in the shell history or not. Defaults to True.
        cmd_override (str, optional): the entrypoint command to use, similar to a dockerfile. Defaults to "./<bash_file" internally.

    Returns:
        platform.ShellServiceResponse: the structured response from running the file.
    """
    # Check if the file exists in the current working directory
    if os.path.exists(bash_file):
        logger.info(f"File '{bash_file}' found in the current working directory.")
    else:
        cwd = os.getcwd()
        rw_path_to_robot = resolve_path_to_robot()
        ## Users will expect to run the command from within the current working directory
        ## Here we will rewrite the path so that it executes properly from the cwd
        if rw_path_to_robot:
            # Split the path at the patterns you provided and join with the new prefix
            for pattern in ["sli.robot", "runbook.robot"]:
                if pattern in rw_path_to_robot:
                    path, _ = rw_path_to_robot.split(pattern)
                    # if cwd == runwhen_home:
                    #     new_path = path
                    # else:
                    #     # This for backwards compatibility for older images
                    #     # that have /collection at the root 
                    #     new_path = os.path.join("/collection", path)
                    # # Modify the bash_file to point to the new directory
                    local_bash_file = f"./{bash_file}"
                    bash_file = os.path.join(path, bash_file)
                    if os.path.exists(bash_file):
                        logger.info(
                            f"File '{bash_file}' found at derived path: {path}."
                        )
                        if cmd_override:
                            cmd_override = cmd_override.replace(
                                f"{local_bash_file}", f"{bash_file}"
                            )
                        else:
                            cmd_override = f"{bash_file}"
                        break
                    else:
                        logger.warning(
                            f"File '{bash_file}' not found at derived path: {path}."
                        )
        else:
            logger.warning(
                f"Current directory is '{cwd}', but 'RW_PATH_TO_ROBOT' is not set."
            )
    if not cmd_override:
        cmd_override = f"./{bash_file}"
    logger.info(f"Received kwargs: {kwargs}")
    request_secrets = _create_secrets_from_kwargs(**kwargs)
    file_contents: str = ""
    with open(f"{bash_file}", "r") as fh:
        file_contents = fh.read()
    logger.info(f"Script file contents:\n\n{file_contents}")
    rsp = execute_command(
        cmd=cmd_override,
        files={f"{bash_file}": file_contents},
        service=target_service,
        request_secrets=request_secrets,
        env=env,
        timeout_seconds=timeout_seconds,
    )
    if include_in_history:
        SHELL_HISTORY.append(file_contents)
    logger.info(f"shell stdout: {rsp.stdout}")
    logger.info(f"shell stderr: {rsp.stderr}")
    logger.info(f"shell status: {rsp.status}")
    logger.info(f"shell returncode: {rsp.returncode}")
    logger.info(f"shell rsp: {rsp}")
    return rsp


def run_cli(
    cmd: str,
    target_service: platform.Service = None,
    env: dict = None,
    loop_with_items: list = None,
    run_in_workload_with_name: str = "",
    run_in_workload_with_labels: str = "",
    optional_namespace: str = "",
    optional_context: str = "",
    include_in_history: bool = True,
    timeout_seconds: int = 60,
    debug: bool = True,
    **kwargs,
) -> platform.ShellServiceResponse:
    """Executes a string of shell commands either locally or remotely on a shellservice.

    For passing through secrets securely this can be done by using kwargs with a specific naming convention:
    - for files: secret_file__kubeconfig
    - for secret strings: secret__mytoken

    and then to use these within your shell command use the following syntax: $${<secret_name>.key} which will cause the shell command to access where
    the secret is stored in the environment it's running in.

    Args:
        cmd (str): the string of shell commands to run, eg: ls -la | grep myfile
        target_service (platform.Service, optional): the remote shellservice to run the commands on if provided, otherwise run locally if None. Defaults to None.
        env (dict, optional): a mapping of environment variables to set in the environment where the shell commands are run. Defaults to None.
        loop_with_items (list, optional): deprecated. Defaults to None.
        run_in_workload_with_name (str, optional): deprecated. Defaults to "".
        run_in_workload_with_labels (str, optional): deprecated. Defaults to "".
        optional_namespace (str, optional): deprecated. Defaults to "".
        optional_context (str, optional): deprecated. Defaults to "".
        include_in_history (bool, optional): whether or not to include the shell commands in the total history. Defaults to True.

    Returns:
        platform.ShellServiceResponse: the structured response from running the shell commands.
    """
    global SHELL_HISTORY
    looped_results = []
    rsp = None
    logger.info(
        f"Requesting command: {cmd} with service: {target_service} - None indicates run local"
    )
    if run_in_workload_with_labels or run_in_workload_with_name:
        cmd = _create_kubernetes_remote_exec(
            cmd=cmd,
            target_service=target_service,
            env=env,
            labels=run_in_workload_with_labels,
            workload_name=run_in_workload_with_name,
            namespace=optional_namespace,
            context=optional_context,
            **kwargs,
        )
    request_secrets: [platform.ShellServiceRequestSecret] = (
        [] if len(kwargs.keys()) > 0 else None
    )
    logger.info(f"Received kwargs: {kwargs}")
    request_secrets = _create_secrets_from_kwargs(**kwargs)
    if loop_with_items and len(loop_with_items) > 0:
        for item in loop_with_items:
            cmd = cmd.format(item=item)
            iter_rsp = execute_command(
                cmd=cmd,
                service=target_service,
                request_secrets=request_secrets,
                env=env,
                timeout_seconds=timeout_seconds,
            )
            if include_in_history:
                SHELL_HISTORY.append(cmd)
            looped_results.append(iter_rsp.stdout)
            # keep track of last rsp codes we got
            # TODO: revisit how we aggregate these
            rsp = iter_rsp
        aggregate_stdout = "\n".join([iter_stdout for iter_stdout in looped_results])
        rsp = platform.ShellServiceResponse(
            cmd=rsp.cmd,
            parsed_cmd=rsp.parsed_cmd,
            stdout=aggregate_stdout,
            stderr=rsp.stderr,
            returncode=rsp.returncode,
            status=rsp.status,
            body=rsp.body,
            errors=rsp.errors,
        )
    else:
        rsp = execute_command(
            cmd=cmd,
            service=target_service,
            request_secrets=request_secrets,
            env=env,
            timeout_seconds=timeout_seconds,
        )
        if include_in_history:
            SHELL_HISTORY.append(cmd)
    if debug:
        logger.info(f"shell stdout: {rsp.stdout}")
        logger.info(f"shell stderr: {rsp.stderr}")
        logger.info(f"shell status: {rsp.status}")
        logger.info(f"shell returncode: {rsp.returncode}")
        logger.info(f"shell rsp: {rsp}")
    return rsp


def string_to_datetime(duration_str: str) -> datetime:
    """
    Helper to convert readable duration strings (eg: 1d2m36s) to a datetime.
    """
    return _string_to_datetime(duration_str)
