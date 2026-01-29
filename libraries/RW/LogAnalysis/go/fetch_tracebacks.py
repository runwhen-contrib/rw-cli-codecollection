"""
Extract Go stack traces (panic / goroutine) from log lines.

Handles:
- panic: runtime error: ...
- [signal SIGSEGV: ...]
- goroutine N [running]:
- Frame lines: package.(*Type).Method(...) and /path/file.go:line +0xhex
- JSON-wrapped logs where message contains panic or following lines are raw stack
"""

import json
import re
from typing import List

from robot.api import logger

# Start of a Go panic line
GO_PANIC = re.compile(r"panic\s*:")
# goroutine N [running]:
GO_GOROUTINE = re.compile(r"goroutine\s+\d+\s+\[running\]\s*:")
# Location line: whitespace + /path/file.go:line +0xhex
GO_LOCATION = re.compile(r"^\s+/.+\.go:\d+\s+\+\d+x[0-9a-fA-F]+")
# [signal SIGSEGV: ...]
GO_SIGNAL = re.compile(r"\[\s*signal\s+\w+")
# Go stack frame: package.path or package.(*Type).Method( - optional continuation with {0x...}
GO_FRAME = re.compile(r"^\s*(?:[\w./]+\.\(?\*?\w+\)?\.?\w*|[\w./]+)\s*\(")
# Line that looks like Go pointer/struct fragment (e.g. {0xe3d278, 0xc000411c50})
GO_POINTER_FRAGMENT = re.compile(r"^\s*\{0x[0-9a-fA-F]+")
# New JSON log line (starts with {" and has "message" or "timestamp")
JSON_LOG_START = re.compile(r'^\s*\{\s*"')


def _is_go_stack_line(line: str) -> bool:
    """Return True if this line looks like part of a Go stack trace."""
    s = line.strip()
    if not s:
        return False
    if GO_PANIC.search(s):
        return True
    if GO_GOROUTINE.search(s):
        return True
    if GO_SIGNAL.search(s):
        return True
    if GO_LOCATION.match(line):
        return True
    if GO_FRAME.match(line):
        return True
    # Continuation of a frame (e.g. {0xe3d278, 0xc000411c50}, 0xc00040ae70)
    if GO_POINTER_FRAGMENT.match(line) or (
        "0x" in s and ("}" in s or ")" in s) and re.search(r"0x[0-9a-fA-F]+", s)
    ):
        return True
    return False


def _starts_go_traceback(line: str) -> bool:
    """Return True if this line starts a new Go traceback (panic or goroutine)."""
    s = line.strip()
    return bool(GO_PANIC.search(s) or GO_GOROUTINE.search(s))


def _timestamp_from_json_line(line: str) -> str:
    """If line is a JSON log with timestamp, return it; else return ''."""
    try:
        if not line.strip().startswith("{"):
            return ""
        obj = json.loads(line)
        if isinstance(obj, dict):
            ts = obj.get("timestamp") or obj.get("time") or ""
            return str(ts) if ts else ""
    except Exception:
        pass
    return ""


class GoTracebackExtractor:
    """
    Extract Go panic/goroutine stack traces from log lines.
    Returns the same shape as Java/Python extractors: list of {"timestamp": str, "stacktrace": str}.
    """

    def extract_tracebacks_from_logs(self, logs: List[str]) -> List[dict]:
        """
        Extract Go stack traces from a list of log lines.
        Handles mixed JSON log lines and raw stack lines.
        """
        if not logs:
            return []
        tracebacks: List[dict] = []
        i = 0
        while i < len(logs):
            line = logs[i]
            if not _starts_go_traceback(line):
                # Check if it's a JSON line whose message contains panic/goroutine
                ts = _timestamp_from_json_line(line)
                if ts:
                    # Look inside message for start of panic
                    try:
                        obj = json.loads(line)
                        msg = (obj.get("message") or obj.get("msg") or "") if isinstance(obj, dict) else ""
                        if msg and (_starts_go_traceback(msg) or "panic" in msg.lower()):
                            # Collect this message and following stack lines
                            block = [msg]
                            j = i + 1
                            while j < len(logs) and _is_go_stack_line(logs[j]):
                                block.append(logs[j])
                                j += 1
                            if len(block) > 1 or "panic" in msg.lower() or "goroutine" in msg.lower():
                                tracebacks.append({
                                    "timestamp": ts,
                                    "stacktrace": "\n".join(block),
                                })
                            i = j
                            continue
                    except Exception:
                        pass
                i += 1
                continue

            # Start of raw Go traceback
            timestamp = ""
            if i > 0:
                timestamp = _timestamp_from_json_line(logs[i - 1])

            block = [line]
            i += 1
            while i < len(logs):
                next_line = logs[i]
                if not next_line.strip():
                    # Single blank line may separate panic/signal from "goroutine N [running]:"
                    if i + 1 < len(logs) and (
                        GO_GOROUTINE.search(logs[i + 1].strip())
                        or _is_go_stack_line(logs[i + 1])
                    ):
                        block.append(next_line)
                        i += 1
                        continue
                    break
                if JSON_LOG_START.match(next_line):
                    break
                if _is_go_stack_line(next_line) or next_line.strip().startswith("created by"):
                    block.append(next_line)
                    i += 1
                else:
                    # Optional: next line might be "stream closed" or similar trailer
                    if i + 1 < len(logs) and _is_go_stack_line(logs[i + 1]):
                        i += 1
                        continue
                    break

            if block:
                tracebacks.append({
                    "timestamp": timestamp,
                    "stacktrace": "\n".join(block),
                })
        return tracebacks

    def extract_tracebacks_from_log_files(
        self, log_files: List[str], fast_exit: bool = False
    ) -> List[dict]:
        """Read log files and extract Go stack traces. Same contract as Java/Python extractors."""
        all_tracebacks: List[dict] = []
        for log_file_path in log_files:
            try:
                with open(log_file_path, "r", encoding="utf-8", errors="ignore") as f:
                    log_lines = [line.rstrip("\n") for line in f]
                file_tracebacks = self.extract_tracebacks_from_logs(log_lines)
                all_tracebacks.extend(file_tracebacks)
                if fast_exit and file_tracebacks:
                    return file_tracebacks[:1]
            except Exception as e:
                logger.error(
                    f"Error processing log file {log_file_path} by go traceback extractor: {e}"
                )
        return all_tracebacks
