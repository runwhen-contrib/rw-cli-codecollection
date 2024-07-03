import os, logging
from RW.K8sApplications.parsers import *
from RW.K8sApplications.k8s_applications import parse_stacktraces, ParseMode, stacktrace_report
from RW.K8sApplications.parsers import BaseStackTraceParse, PythonStackTraceParse, GoLangStackTraceParse

logger = logging.getLogger(__name__)

THIS_DIR: str = "/".join(__file__.split("/")[:-1])
TEST_DATA_DIR = "test_data"
MAX_LOG_LINES: int = 1025


def test_python_parser():
    logger.info("Testing python parser")
    with open(f"{THIS_DIR}/{TEST_DATA_DIR}/python.log", "r") as f:
        data = f.read()
    if len(data) > MAX_LOG_LINES:
        logger.warning(
            f"Length of logs provided for parsing stacktraces is greater than {MAX_LOG_LINES}, be aware this could effect performance"
        )
    print(f"Log data: {data}")
    results = parse_stacktraces(
        data, parse_mode=ParseMode.MULTILINE_LOG, parser_override=PythonStackTraceParse, show_debug=True
    )
    print(f"Result: {results}")
    assert len(results) > 0
    assert results[0].urls == []
    assert results[0].endpoints == []
    assert results[0].files == ["main.py"]
    assert results[0].line_nums == {"main.py": [10]}
    assert results[0].error_messages == ["KeyError: 'missing_key'"]
    assert results[0].parser_used_type == "PythonStackTraceParse"


def test_golang_parser():
    logger.info("Testing golang parser")
    with open(f"{THIS_DIR}/{TEST_DATA_DIR}/golang.log", "r") as f:
        data = f.read()
    if len(data) > MAX_LOG_LINES:
        logger.warning(
            f"Length of logs provided for parsing stacktraces is greater than {MAX_LOG_LINES}, be aware this could effect performance"
        )
    print(f"Log data: {data}")
    results = parse_stacktraces(
        data, parse_mode=ParseMode.MULTILINE_LOG, parser_override=GoLangStackTraceParse, show_debug=True
    )
    print(f"Result: {results}")
    assert len(results) > 0
    assert results[0].urls == []
    assert results[0].endpoints == []
    assert "/src/handlers.go" in results[0].files
    assert results[0].line_nums["/src/handlers.go"] == [69]
    assert results[0].line_nums["/src/middleware.go"] == [82, 109]


def test_golang_report():
    logger.info("Testing Report")
    with open(f"{THIS_DIR}/{TEST_DATA_DIR}/golang.log", "r") as f:
        data = f.read()
    if len(data) > MAX_LOG_LINES:
        logger.warning(
            f"Length of logs provided for parsing stacktraces is greater than {MAX_LOG_LINES}, be aware this could effect performance"
        )
    results = parse_stacktraces(
        data, parse_mode=ParseMode.MULTILINE_LOG, parser_override=GoLangStackTraceParse, show_debug=True
    )
    r = stacktrace_report(results)
    print(f"REPORT\n\n{r}\n\n")


if __name__ == "__main__":
    test_python_parser()
    test_golang_parser()
