"""Tests for K8sLog.format_logs_for_report.

Run via: ./test.sh   (or: pytest --log-cli-level=DEBUG _test_log_filter.py)

The helper currently has a STUB implementation in k8s_log.py — these tests
will mostly FAIL until the real implementation lands. That is intentional
for review: the failures show exactly what each assertion is checking.

Each test builds a fake log_dir via pytest's tmp_path fixture, mirroring
the directory layout produced by RW.K8sLog.Fetch Workload Logs:

    <log_dir>/
      <workload_type>_<workload_name>_logs/
        <pod>_<container>_logs.txt
"""

import getpass
import logging
import os
from pathlib import Path

import pytest

from RW.K8sLog import K8sLog

logger = logging.getLogger(__name__)

THIS_DIR = os.path.dirname(__file__)
TEST_DATA_DIR = os.path.join(THIS_DIR, "test_data")


def _read(name: str) -> str:
    with open(os.path.join(TEST_DATA_DIR, name)) as f:
        return f.read()


def _make_log_dir(tmp_path: Path, content: str,
                  workload: str = "deployment_test-app",
                  pod_container: str = "pod-abc_main") -> str:
    """Create a log_dir under tmp_path that mirrors the layout produced
    by RW.K8sLog.Fetch Workload Logs, and write `content` to a single
    pod/container log file inside it.
    """
    logs_subdir = tmp_path / f"{workload}_logs"
    logs_subdir.mkdir()
    log_file = logs_subdir / f"{pod_container}_logs.txt"
    log_file.write_text(content)
    return str(tmp_path)


@pytest.fixture
def k8slog():
    return K8sLog()


def test_happy_path_filters_correctly(k8slog, tmp_path):
    """Plain-text log: noise filter drops health-check lines, signal filter keeps errors/warnings."""
    raw = _read("plain_text.log")
    log_dir = _make_log_dir(tmp_path, raw)
    result = k8slog.format_logs_for_report(log_dir)

    assert result["total_lines"] == 13
    # health_check_lines uses the NARROWER counter regex (matching
    # runbook.robot:473) — only /health, healthcheck, Checking.*Health,
    # Health.*Check. Lines like "probe completed" / "liveness check" /
    # "readiness probe" are dropped by the noise filter but NOT counted
    # here — that asymmetry is preserved from the original bash pipeline.
    # In our fixture: GET /health (×2), POST /health (×1), healthcheck (×1) = 4
    assert result["health_check_lines"] == 4
    assert result["mostly_health_checks"] is False

    filtered = result["filtered"]
    # Signal lines must be preserved
    assert "Database connection refused" in filtered
    assert "Slow query detected" in filtered
    assert "authentication failed" in filtered
    assert "HTTP 503 from upstream" in filtered

    # Health-check noise must be excluded (using the broader noise filter)
    assert "GET /health 200" not in filtered
    assert "POST /health 200" not in filtered
    assert "readiness probe ok" not in filtered

    # Non-signal informational lines must be excluded
    assert "Starting application" not in filtered
    assert "Processing request" not in filtered

    # Context (head 20 | tail 10 of non-noise) — 6 non-noise lines in this
    # fixture, so context contains all of them. Pin the boundary lines.
    context = result["context"]
    assert "Starting application" in context
    assert "HTTP 503 from upstream" in context

    # Raw should contain every line from the input — including health-check
    # noise — so callers that want to dump unfiltered logs can use it.
    raw = result["raw"]
    assert "Starting application" in raw
    assert "GET /health 200" in raw            # noise — present in raw
    assert "HTTP 503 from upstream" in raw     # signal — present in raw


def test_metacharacter_payload_does_not_crash(k8slog, tmp_path):
    """JSON access logs containing (, ', ;, $(...), backticks — content that broke bash.

    The old shell pipeline died on this with `syntax error near unexpected token '('`.
    The Python helper must process it without raising.
    """
    raw = _read("json_with_metachars.log")
    log_dir = _make_log_dir(tmp_path, raw)
    result = k8slog.format_logs_for_report(log_dir)

    assert isinstance(result, dict)
    assert isinstance(result["filtered"], str)
    assert result["total_lines"] == 3
    assert result["health_check_lines"] == 0
    # The single ERROR line should survive the filter
    assert "connection refused" in result["filtered"]


def test_oversized_payload_does_not_crash(k8slog, tmp_path):
    """JSON access logs at production volume — pushed past the 128 KB
    MAX_ARG_STRLEN that crashed the old shell version with
    OSError [Errno 7] Argument list too long.

    Uses the same JSON fixture as test_metacharacter_payload_does_not_crash
    so this test exercises both stressors (size + metacharacters) together —
    which is exactly how the original prod failure manifested.
    """
    base = _read("json_with_metachars.log")          # 3 lines, ~1.4 KB
    multiplier = (200_000 // len(base)) + 1           # push past 128 KB MAX_ARG_STRLEN
    raw = base * multiplier

    assert len(raw) > 200_000  # sanity check on the constructed payload

    log_dir = _make_log_dir(tmp_path, raw)
    result = k8slog.format_logs_for_report(log_dir)

    assert result["total_lines"] == 3 * multiplier
    assert result["health_check_lines"] == 0
    assert result["mostly_health_checks"] is False
    assert "connection refused" in result["filtered"]


def test_empty_input(k8slog, tmp_path):
    """A log file that exists but is empty must return zero counts and empty fields, not raise."""
    log_dir = _make_log_dir(tmp_path, "")
    result = k8slog.format_logs_for_report(log_dir)

    assert result["total_lines"] == 0
    assert result["health_check_lines"] == 0
    assert result["filtered"] == ""
    assert result["context"] == ""
    assert result["mostly_health_checks"] is False


def test_shell_metacharacters_are_inert(k8slog, tmp_path):
    """Regression: $(...) and backticks must appear literally in returned output.

    Proves that no shell is invoked anywhere in the pipeline. If a shell
    were involved, $(whoami) would be replaced by the running user's name
    and `id` would be replaced by the output of id(1).
    """
    raw = "ERROR command failed: $(whoami) and `id` should be literal\n"
    log_dir = _make_log_dir(tmp_path, raw)
    result = k8slog.format_logs_for_report(log_dir)

    assert "$(whoami)" in result["filtered"]
    assert "`id`" in result["filtered"]

    current_user = getpass.getuser()
    assert current_user not in result["filtered"], (
        f"Username {current_user!r} appeared in filtered output — "
        "a shell expanded $(whoami) somewhere in the pipeline."
    )
