"""
CLI Generic keyword library for running and parsing CLI stdout

Scope: Global
"""
import re, logging, json, jmespath
from robot.libraries.BuiltIn import BuiltIn

from RW import platform
from RW.Core import Core

# import bare names for robot keyword names
from .json_parser import *
from .stdout_parser import *
from .cli_utils import _string_to_datetime, from_json

logger = logging.getLogger(__name__)

ROBOT_LIBRARY_SCOPE = "GLOBAL"

SHELL_HISTORY: list[str] = []


def pop_shell_history() -> str:
    global SHELL_HISTORY
    history: str = "\n".join(SHELL_HISTORY)
    SHELL_HISTORY = []
    return history


def run_cli(
    cmd: str,
    target_service: platform.Service,
    env: dict = None,
    loop_with_items: list = None,
    **kwargs,
) -> platform.ShellServiceResponse:
    global SHELL_HISTORY
    looped_results = []
    rsp = None
    secret_prefix = "secret__"
    secret_file_prefix = "secret_file__"
    if not target_service:
        raise ValueError("A runwhen service was not provided for the cli command")
    logger.info(f"Requesting command: {cmd}")
    request_secrets: [platform.ShellServiceRequestSecret] = [] if len(kwargs.keys()) > 0 else None
    logger.info(f"Received kwargs: {kwargs}")
    for key, value in kwargs.items():
        if not isinstance(value, platform.Secret):
            logger.warning(f"kwarg secret {value} in key {key} is the wrong type, should be platform.Secret")
            continue
        if key.startswith(secret_prefix):
            request_secrets.append(platform.ShellServiceRequestSecret(value))
        elif key.startswith(secret_file_prefix):
            request_secrets.append(platform.ShellServiceRequestSecret(value, as_file=True))
    if loop_with_items and len(loop_with_items) > 0:
        for item in loop_with_items:
            cmd = cmd.format(item=item)
            iter_rsp = platform.execute_shell_command(
                cmd=cmd, service=target_service, request_secrets=request_secrets, env=env
            )
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
        rsp = platform.execute_shell_command(cmd=cmd, service=target_service, request_secrets=request_secrets, env=env)
        SHELL_HISTORY.append(cmd)
    logger.info(f"shell stdout: {rsp.stdout}")
    logger.info(f"shell stderr: {rsp.stderr}")
    logger.info(f"shell status: {rsp.status}")
    logger.info(f"shell returncode: {rsp.returncode}")
    logger.info(f"shell rsp: {rsp}")
    return rsp


def string_to_datetime(duration_str: str) -> datetime:
    return _string_to_datetime(duration_str)
