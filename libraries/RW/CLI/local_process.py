""" TODO: should be incorporated into platform behaviour
 Acts as interoperable layer between ShellRequest/Response and local processes - hacky
"""
import os, re, subprocess, shlex, glob, importlib, traceback, sys, tempfile, shutil
import logging

from RW import platform
from RW.Core import Core

logger = logging.getLogger(__name__)

PWD = "."
RF_ENV_PATTERN = re.compile(r'\\%(?=\{)')

def _deserialize_secrets(
    request_secrets: list[platform.ShellServiceRequestSecret] = [],
) -> list:
    ds_secrets = [
        {"key": ssrs.secret.key, "value": ssrs.secret.value, "file": ssrs.as_file}
        for ssrs in request_secrets
    ]
    return ds_secrets


def execute_local_command(
    cmd: str,
    request_secrets: list[platform.ShellServiceRequestSecret] = [],
    env: dict = {},
    files: dict = {},
    timeout_seconds: int = 60,
):
    # handles edge case where CLI tool syntax matches robotframework env vars and has to be escaped
    cmd = RF_ENV_PATTERN.sub('%', cmd)
 
    USER_ENV: str = os.getenv("USER", None)
    # logging.info(f"Local process user detected as: {USER_ENV}")
    # if not USER_ENV:
    #     raise Exception(f"USER environment variable not properly set, found: {USER_ENV}")
    request_secrets = request_secrets if request_secrets else []
    if request_secrets:
        request_secrets = _deserialize_secrets(request_secrets=request_secrets)
    env = env if env else {}
    files = files if files else {}
    out = None
    err = None
    rc = -1
    parsed_cmd = None
    errors = []
    tmpdir = None
    run_with_env = {}
    # Define the keys we want to check in the current environment for proxy settings / ca settings
    keys_to_check = [
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "REQUESTS_CA_BUNDLE",
        "CURL_CA_BUNDLE", "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS"
    ]

    # Update run_with_env with the environment variables that are set
    run_with_env.update({key: os.getenv(key) for key in keys_to_check if os.getenv(key)})

    # If additional environment settings are provided, update run_with_env with these,
    # potentially overwriting the previously set values
    if env:
        run_with_env.update(env)
    try:
        tmpdir = tempfile.mkdtemp(dir=PWD)
        parsed_cmd = ["bash", "-c", cmd]
        secret_keys = []
        for s in request_secrets:
            if s["file"]:
                secret_key = s["key"]
                secret_keys.append(secret_key)
                secret_file_path = os.path.join(tmpdir, secret_key)
                with open(secret_file_path, "w") as tmp:
                    tmp.write(s["value"])
                run_with_env[secret_key] = secret_file_path
            else:
                if run_with_env.get(s["key"], None):
                    errors.append(
                        f"Secret given attempted to over-write an existing env var {s.name}"
                    )
                    break
                run_with_env[s["key"]] = s["value"]
        file_paths = []
        for fname, content in files.items():
            file_path = os.path.join(tmpdir, fname)
            file_paths.append(file_path)
            with open(file_path, "w") as tmp:
                tmp.write(content)
        logger.debug(
            f"running {parsed_cmd} with env {run_with_env.keys()} and files {files.keys()}, secret names {secret_keys}"
        )
        # enable file permissions
        if USER_ENV:
            p = subprocess.run(
                ["chown", USER_ENV, "."],
                text=True,
                capture_output=True,
                timeout=timeout_seconds,
                cwd=os.path.abspath(tmpdir),
            )
            p = subprocess.run(
                ["chmod", "-R", "u+x", "."],
                text=True,
                capture_output=True,
                timeout=timeout_seconds,
                cwd=os.path.abspath(tmpdir),
            )
        p = subprocess.run(
            parsed_cmd,
            text=True,
            capture_output=True,
            timeout=timeout_seconds,
            env=run_with_env,
            cwd=os.path.abspath(tmpdir),
        )
        out = p.stdout
        err = p.stderr
        rc = p.returncode
        logger.debug(
            f"ran {parsed_cmd} with env {run_with_env.keys()} and files {files.keys()}, secret names {secret_keys}, resulted in returncode {rc}, stdout {out}, stderr {err}"
        )
    except Exception as e:
        s = traceback.format_exception(*sys.exc_info())
        msg = f"Exception while running {parsed_cmd} with env {run_with_env.keys()} and files {files.keys()}, secret names {secret_keys}: {type(e)}: {e}\n{s}"
        errors.append(msg)
        rc = -1
        logger.error(msg)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    proc_data: dict = {
        "cmd": cmd,
        # TODO: Fix odd key name
        "parsedCmd": parsed_cmd,
        "stdout": out,
        "stderr": err,
        "returncode": rc,
        "errors": errors,
    }
    return platform.ShellServiceResponse.from_json(proc_data)
