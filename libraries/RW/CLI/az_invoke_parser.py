"""
CLI parser to extract stdout and stderr from Azure invoke raw output.

Scope: Global
"""

import os
import json
import logging

from RW import platform
from RW.Core import Core
from RW.CLI.local_process import execute_local_command

logger = logging.getLogger(__name__)
ROBOT_LIBRARY_SCOPE = "GLOBAL"

def run_invoke_cmd_parser(input_file: str, timeout_seconds: int = 60) -> platform.ShellServiceResponse:
    """
    Parses the output of an Azure invoke command stored in a file,
    extracting stdout and stderr sections.

    Args:
        input_file: Path to the file containing the raw invoke output.
        timeout_seconds: (Optional) Timeout for compatibility; not used in parsing.

    Returns:
        A ShellServiceResponse-like object with .stdout and .stderr populated.
    """
    if not os.path.isfile(input_file):
        raise FileNotFoundError(f"Input file '{input_file}' does not exist.")

    with open(input_file, "r", encoding="utf-8") as f:
        raw = f.read()

    stdout, stderr = "", ""

    if "[stdout]" in raw:
        stdout = raw.split("[stdout]")[1].split("[stderr]")[0].strip() if "[stderr]" in raw else raw.split("[stdout]")[1].strip()
    if "[stderr]" in raw:
        stderr = raw.split("[stderr]")[1].strip()

    parsed = {
        "stdout": stdout,
        "stderr": stderr,
        "status": "success",
        "returncode": 0
    }

    logger.info("Parsed stdout:\n" + stdout)
    logger.info("Parsed stderr:\n" + stderr)

    return platform.ShellServiceResponse.from_dict(parsed)
