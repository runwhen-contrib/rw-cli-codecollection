import os
import getpass
import re
import subprocess
import shlex
import logging
import traceback
import sys

from RW import platform
from RW.Core import Core

logger = logging.getLogger(__name__)

PWD = "."
RF_ENV_PATTERN = re.compile(r"\\%(?=\{)")

def _deserialize_secrets(request_secrets: list[platform.ShellServiceRequestSecret] = None) -> list:
    """
    Convert the platform.ShellServiceRequestSecret objects into a simpler list
    of dicts: {"key": ..., "value": ..., "file": bool}.
    """
    if not request_secrets:
        return []
    return [
        {"key": ssrs.secret.key, "value": ssrs.secret.value, "file": ssrs.as_file}
        for ssrs in request_secrets
    ]

def execute_local_command(
    cmd: str,
    request_secrets: list[platform.ShellServiceRequestSecret] = None,
    env: dict = None,
    files: dict = None,
    timeout_seconds: int = 60,
    cwd: str = None, 
) -> platform.ShellServiceResponse:
    """
    Runs a local bash command via subprocess, with optional secrets, environment, and file copying.
    Instead of ephemeral mkdtemp usage, we store everything in CODEBUNDLE_TEMP_DIR if set,
    otherwise in the current directory, so the files persist after execution.

    Args:
        cmd (str): The command to run (e.g., "ls -l").
        request_secrets (list): Secrets to inject either as environment variables or as files.
        env (dict): Additional environment variables for this process.
        files (dict): A dict of filename -> contents to be written in the working directory.
        timeout_seconds (int): Subprocess timeout.

    Returns:
        platform.ShellServiceResponse
    """
    if request_secrets is None:
        request_secrets = []
    if env is None:
        env = {}
    if files is None:
        files = {}

    # 1) Clean up Robot-specific escapes
    cmd = RF_ENV_PATTERN.sub("%", cmd)

    # 2) Determine the final working directory
    #    - If CODEBUNDLE_TEMP_DIR is set, use it
    #    - Otherwise fallback to the current directory.
    codebundle_temp_dir = os.getenv("CODEBUNDLE_TEMP_DIR")
    if codebundle_temp_dir:
        os.makedirs(codebundle_temp_dir, exist_ok=True)
        final_cwd = codebundle_temp_dir
        logger.debug(f"Using CODEBUNDLE_TEMP_DIR for local command: {final_cwd}")
    else:
        final_cwd = os.path.abspath(PWD)
        logger.debug(f"CODEBUNDLE_TEMP_DIR not set; using PWD for local command: {final_cwd}")

    # 3) Prepare the environment
    #    a) Start with certain environment variables from the OS (like proxy/SSL)
    #    b) Overlay any new environment variables from `env`
    run_with_env = {}
    keys_to_check = [
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY",
        "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE",
        "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS"
    ]
    for key in keys_to_check:
        val = os.getenv(key)
        if val:
            run_with_env[key] = val

    run_with_env.update(env)  # overlay user-provided

    # 4) Deserialize secrets. If as_file=True, write a file in final_cwd
    secret_keys = []
    ds_secrets = _deserialize_secrets(request_secrets)
    for s in ds_secrets:
        if s["file"]:
            secret_key = s["key"]
            secret_keys.append(secret_key)
            secret_file_path = os.path.join(final_cwd, secret_key)
            with open(secret_file_path, "w") as tmpf:
                tmpf.write(s["value"])
            # Expose path in environment
            run_with_env[secret_key] = secret_file_path
        else:
            # inline secret as environment variable
            run_with_env[s["key"]] = s["value"]

    # 5) Copy any additional 'files' into final_cwd
    for fname, content in files.items():
        file_path = os.path.join(final_cwd, fname)
        with open(file_path, "w") as tmpf:
            tmpf.write(content)

    # 6) We might also set ownership/permissions if needed
    user_env = os.getenv("USER", getpass.getuser())
    try:
        subprocess.run(
            ["chown", user_env, final_cwd],
            check=False,  # ignore errors if not root
            text=True,
            capture_output=True,
            timeout=timeout_seconds
        )
        subprocess.run(
            ["chmod", "-R", "u+x", final_cwd],
            check=False,
            text=True,
            capture_output=True,
            timeout=timeout_seconds
        )
    except Exception as e:
        logger.debug(f"Ignoring error while adjusting permissions in {final_cwd}: {e}")

    # 7) Run the command
    out, err = None, None
    rc = -1
    errors = []
    parsed_cmd = ["bash", "-c", cmd]

    logger.debug(
        f"Running command {parsed_cmd} in cwd={final_cwd}, "
        f"env={list(run_with_env.keys())}, secrets={secret_keys}, files={list(files.keys())}"
    )

    try:
        p = subprocess.run(
            parsed_cmd,
            text=True,
            capture_output=True,
            timeout=timeout_seconds,
            env=run_with_env,
            cwd=final_cwd
        )
        out = p.stdout
        err = p.stderr
        rc = p.returncode
        logger.debug(
            f"Command finished with returncode={rc}, stdout={out}, stderr={err}"
        )
    except Exception as e:
        trace = traceback.format_exception(*sys.exc_info())
        msg = (f"Exception while running {parsed_cmd} in {final_cwd}:\n"
               f"{type(e)}: {e}\n{''.join(trace)}")
        logger.error(msg)
        errors.append(msg)

    # 8) Build the ShellServiceResponse
    proc_data = {
        "cmd": cmd,
        "parsedCmd": parsed_cmd,
        "stdout": out,
        "stderr": err,
        "returncode": rc,
        "errors": errors,
    }
    return platform.ShellServiceResponse.from_json(proc_data)
