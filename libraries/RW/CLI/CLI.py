"""
CLI Generic keyword library for running and parsing CLI stdout

Scope: Global
"""
import re, logging, json, jmespath, os, tempfile
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
    cwd: str = None, 
) -> platform.ShellServiceResponse:
    """
    If 'service' is None, run the command locally via 'execute_local_command'.
    Otherwise, run it via 'platform.execute_shell_command'.
    """
    if env is None:
        env = {}

    azure_config_dir = os.getenv("AZURE_CONFIG_DIR")
    if azure_config_dir and "AZURE_CONFIG_DIR" not in env:
        env["AZURE_CONFIG_DIR"] = azure_config_dir

    codebundle_temp_dir = os.getenv("CODEBUNDLE_TEMP_DIR")
    if codebundle_temp_dir and "CODEBUNDLE_TEMP_DIR" not in env:
        env["CODEBUNDLE_TEMP_DIR"] = codebundle_temp_dir

    gcloud_config_dir = os.getenv("CLOUDSDK_CONFIG")
    if gcloud_config_dir and "CLOUDSDK_CONFIG" not in env:
        env["CLOUDSDK_CONFIG"] = gcloud_config_dir

    # Possibly pass 'files' as well
    # request_secrets is already handled
    if service:
        # For a remote service, 'cwd' typically doesn't apply 
        # unless the remote shell supports specifying a directory.
        return platform.execute_shell_command(
            cmd=cmd,
            service=service,
            request_secrets=request_secrets,
            env=env,
            files=files,
            # There's no 'cwd' usage in remote calls, so we omit it
        )
    else:
        # Local
        return execute_local_command(
            cmd=cmd,
            request_secrets=request_secrets,
            env=env,
            files=files,
            timeout_seconds=timeout_seconds,
            cwd=cwd, 
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
    """
    Runs a bash file from the local file system or remotely on a shellservice,
    automatically staging it in CODEBUNDLE_TEMP_DIR if available.

    1) Find the local path to `bash_file` (or fallback via resolve_path_to_robot).
    2) Copy that script and all sibling files into CODEBUNDLE_TEMP_DIR (if set),
       or else an ephemeral tmp directory.
    3) Call `execute_command()` to actually run the script from that directory.
    4) If 'service' is provided, run on a remote shell; if not, run locally.

    Secrets and environment variables (e.g., AZURE_CONFIG_DIR) are still handled
    automatically in `execute_command()`.
    """
    if env is None:
        env = {}

    # ----------------------------------------------------------------
    # 1) Locate the script
    # ----------------------------------------------------------------
    if os.path.exists(bash_file):
        logger.info(f"File '{bash_file}' found in the current working directory.")
        final_path = os.path.abspath(bash_file)
    else:
        # Not found directly, so do fallback logic with resolve_path_to_robot
        cwd = os.getcwd()
        logger.warning(f"File '{bash_file}' not found in '{cwd}'. Attempting fallback logic...")

        # Might return something like "/path/to/.../sli.robot"
        rw_path_to_robot = resolve_path_to_robot()

        found = False
        if rw_path_to_robot:
            for pattern in ["sli.robot", "runbook.robot"]:
                if pattern in rw_path_to_robot:
                    path_prefix, _ = rw_path_to_robot.split(pattern)
                    candidate_path = os.path.join(path_prefix, bash_file)
                    if os.path.exists(candidate_path):
                        final_path = os.path.abspath(candidate_path)
                        logger.info(f"File '{bash_file}' found at: {final_path}")
                        found = True
                        break
        if not found:
            msg = f"Could not locate bash_file '{bash_file}' even after fallback logic."
            logger.error(msg)
            raise FileNotFoundError(msg)

    if not os.path.isfile(final_path):
        raise FileNotFoundError(f"File does not exist: '{final_path}'")

    final_dir = os.path.dirname(final_path)
    script_name = os.path.basename(final_path)

    # ----------------------------------------------------------------
    # 2) Determine where to stage the script (CODEBUNDLE_TEMP_DIR or ephemeral)
    # ----------------------------------------------------------------
    codebundle_temp_dir = os.getenv("CODEBUNDLE_TEMP_DIR")
    if codebundle_temp_dir:
        # We'll place the files physically in CODEBUNDLE_TEMP_DIR
        os.makedirs(codebundle_temp_dir, exist_ok=True)
        staging_dir = codebundle_temp_dir
        logger.info(f"Staging bash files in CODEBUNDLE_TEMP_DIR: {staging_dir}")
    else:
        # Fallback to ephemeral directory
        staging_dir = tempfile.mkdtemp(prefix="bashfile-", dir=os.getcwd())
        logger.info(f"CODEBUNDLE_TEMP_DIR not set. Using ephemeral staging dir: {staging_dir}")

    # ----------------------------------------------------------------
    # 3) Copy all files from the original directory into staging_dir
    # ----------------------------------------------------------------
    files_dict = {}
    for fname in os.listdir(final_dir):
        full_path = os.path.join(final_dir, fname)
        if os.path.isfile(full_path):
            with open(full_path, "r", encoding="utf-8") as fh:
                content = fh.read()
            files_dict[fname] = content

            # Actually write the file physically to staging_dir
            staged_path = os.path.join(staging_dir, fname)
            with open(staged_path, "w", encoding="utf-8") as out_f:
                out_f.write(content)

    # We'll log the main script's contents if we want
    script_contents = files_dict.get(script_name, "")
    logger.info(f"Script file '{script_name}' contents:\n\n{script_contents}")

    # ----------------------------------------------------------------
    # 4) Prepare the final command override
    # ----------------------------------------------------------------
    if not cmd_override:
        cmd_override = f"./{script_name}"  # run the script in the staging dir

    # ----------------------------------------------------------------
    # 5) Create secrets, if any
    # ----------------------------------------------------------------
    request_secrets = _create_secrets_from_kwargs(**kwargs)

    # ----------------------------------------------------------------
    # 6) Actually run the script from staging_dir
    #    - set `cwd=staging_dir` in the local process so that we can reference
    #      "./scriptname.sh" without specifying a path
    # ----------------------------------------------------------------
    # We'll rely on `execute_command` to eventually call `execute_local_command`,
    # but we need that local function to accept `cwd=staging_dir`.

    # If your existing `execute_local_command` *always* uses a newly mkdtemp,
    # you’ll want to modify it to accept a 'cwd' argument. Something like:
    #
    #   def execute_local_command(cmd, ..., cwd=None):
    #       if cwd is None:
    #           tmpdir = tempfile.mkdtemp(...)
    #           ...
    #       else:
    #           # run from user-specified directory
    #           ...
    #
    # We'll show how you might pass it:

    # Force an environment variable to help debugging
    env["RUN_CMD_FROM"] = staging_dir

    # We'll skip passing `files=files_dict` because we physically wrote them
    # But you could do either approach, if you prefer ephemeral usage from memory.
    rsp = execute_command(
        cmd=cmd_override,
        service=target_service,
        request_secrets=request_secrets,
        env=env,
        files={},                # not strictly needed now that we have physical files
        timeout_seconds=timeout_seconds,
    )

    # If your 'execute_local_command' doesn't yet support `cwd=staging_dir`,
    # you’ll need to add that parameter in the chain. For example:
    #
    #   def execute_command(...):
    #       return execute_local_command(cmd=cmd, ..., cwd=some_path)
    #
    # That ensures we actually run from staging_dir.

    # ----------------------------------------------------------------
    # 7) Optionally store script contents in history
    # ----------------------------------------------------------------
    if include_in_history:
        SHELL_HISTORY.append(script_contents)

    # ----------------------------------------------------------------
    # 8) Log results
    # ----------------------------------------------------------------
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
    """
    Executes a string of shell commands either locally or remotely (if target_service is given).
    - If CODEBUNDLE_TEMP_DIR is set, commands are run from that directory.
    - Preserves the existing logic for:
      * loop_with_items
      * run_in_workload_with_name / run_in_workload_with_labels
      * secrets
      * environment
      * debug/logging
    """

    global SHELL_HISTORY
    looped_results = []
    rsp = None

    logger.info(
        f"Requesting command: {cmd} with service: {target_service} - None indicates run local"
    )

    if env is None:
        env = {}

    # 1) Possibly transform the command to run in a Kubernetes environment
    #    if run_in_workload_with_name or run_in_workload_with_labels is set.
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

    # 2) Convert any secrets from kwargs
    request_secrets: [platform.ShellServiceRequestSecret] = (
        [] if len(kwargs.keys()) > 0 else None
    )
    logger.info(f"Received kwargs: {kwargs}")
    request_secrets = _create_secrets_from_kwargs(**kwargs)

    # 3) We look for CODEBUNDLE_TEMP_DIR
    codebundle_temp_dir = os.getenv("CODEBUNDLE_TEMP_DIR", None)

    # 4) If loop_with_items is given, run the command multiple times with item-based formatting
    if loop_with_items and len(loop_with_items) > 0:
        for item in loop_with_items:
            # Insert 'item' into the command string, e.g. "echo {item}"
            item_cmd = cmd.format(item=item)
            iter_rsp = execute_command(
                cmd=item_cmd,
                service=target_service,
                request_secrets=request_secrets,
                env=env,
                timeout_seconds=timeout_seconds,
                cwd=codebundle_temp_dir,  # run from codebundle_temp_dir if available
            )
            if include_in_history:
                SHELL_HISTORY.append(item_cmd)
            looped_results.append(iter_rsp.stdout)
            # keep track of last response
            rsp = iter_rsp

        # Aggregate stdout from all iterations
        aggregate_stdout = "\n".join(looped_results)
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
        # Single run
        rsp = execute_command(
            cmd=cmd,
            service=target_service,
            request_secrets=request_secrets,
            env=env,
            timeout_seconds=timeout_seconds,
            cwd=codebundle_temp_dir,  # run from codebundle_temp_dir if set
        )
        if include_in_history:
            SHELL_HISTORY.append(cmd)

    # 5) Debug logging
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
