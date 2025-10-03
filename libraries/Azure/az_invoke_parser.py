"""
CLI parser to extract stdout and stderr from Azure invoke raw output.

Scope: Global
"""

import os
import json
import logging
import re

from RW import platform
#from RW.Core import Core

logger = logging.getLogger(__name__)
ROBOT_LIBRARY_SCOPE = "GLOBAL"

def run_invoke_cmd_parser(input_file: str, timeout_seconds: int = 60):
    """
    Parses the output of an Azure invoke command stored in a file,
    extracting stdout and stderr sections from any message containing both.
    """
    if not os.path.isfile(input_file):
        raise FileNotFoundError(f"Input file '{input_file}' does not exist.")

    with open(input_file, "r", encoding="utf-8") as f:
        raw = f.read()

    # Try to parse as JSON
    try:
        data = json.loads(raw)
    except Exception:
        data = None

    stdout, stderr = "", ""

    if isinstance(data, dict) and "value" in data:
        # Azure CLI output is a dict with a "value" list
        for entry in data["value"]:
            msg = entry.get("message", "")
            # Look for both [stdout] and [stderr] in the message
            if "[stdout]" in msg and "[stderr]" in msg:
                # Extract [stdout] and [stderr]
                stdout_match = re.search(r"\[stdout\](.*?)\[stderr\]", msg, re.DOTALL)
                stderr_match = re.search(r"\[stderr\](.*)", msg, re.DOTALL)
                if stdout_match:
                    # Preserve newlines for bash script to read line by line
                    stdout = stdout_match.group(1).replace('\r\n', '\n').strip()
                if stderr_match:
                    stderr = stderr_match.group(1).replace('\r\n', '\n').strip()
                break
    else:
        # Fallback: try to extract from raw text
        if "[stdout]" in raw:
            stdout = raw.split("[stdout]")[1].split("[stderr]")[0].replace('\r\n', '\n').strip() if "[stderr]" in raw else raw.split("[stdout]")[1].replace('\r\n', '\n').strip()
        if "[stderr]" in raw:
            stderr = raw.split("[stderr]")[1].replace('\r\n', '\n').strip()

    parsed = {
        "stdout": stdout,
        "stderr": stderr,
        "status": "success",
        "returncode": 0
    }

    logger.info("Parsed stdout:\n" + stdout)
    logger.info("Parsed stderr:\n" + stderr)

    return parsed
